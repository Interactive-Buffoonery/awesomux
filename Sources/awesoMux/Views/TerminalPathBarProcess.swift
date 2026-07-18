import Darwin
import Foundation

enum BoundedCommandResult: Equatable, Sendable {
    case success(Data)
    case executableNotFound
    case spawnFailure
    case nonZeroExit(Int32)
    case timedOut
    /// Carries the capped buffer: a clean exit whose output hit the cap is
    /// still the Path Bar's pre-existing "truncated but usable" contract
    /// (see `run(arguments:inDirectory:)`), while callers that must not trust
    /// a truncated parse (e.g. `git worktree list --porcelain`) can still
    /// treat this case as a failure without the payload.
    case outputTruncated(Data)
    case outputNotDrained
}

/// Runs a Path Bar status lookup (`git status`, `gh pr view`, `gh run list`) for
/// a repo/branch and returns stdout on success, or nil on any failure (tool
/// missing, non-zero exit, timeout). Injected into the resolvers so tests never
/// shell out.
typealias StatusCommandRunner = @Sendable (_ repoRoot: String, _ branch: String) async -> Data?

/// Runs a bounded external command and returns its stdout on a clean exit
/// (status 0), or nil on any failure (executable missing, non-zero exit,
/// timeout). Shared by the Path Bar's `gh` (PR) and `git` (status) lookups.
///
/// A launched `.app` bundle inherits launchd's minimal PATH, NOT the user's shell
/// PATH, so the executable is resolved by absolute path up front. The call is
/// genuinely bounded: stdout is drained continuously (so a child emitting more
/// than the 64 KB pipe buffer can't block on write), the continuation resumes
/// once the child exits and the pipe reaches EOF — or, if a descendant inherited
/// stdout and holds it open past exit, after a short grace from the collected
/// buffer — and the child is SIGTERM→SIGKILL'd on timeout or task cancellation.
/// stderr is discarded (an undrained stderr pipe that fills would wedge the child).
struct BoundedCommandRunner: Sendable {
    typealias Delay = @Sendable (Duration) async throws -> Void

    let executableURL: URL?
    var timeout: Duration
    /// Hard cap on collected stdout. The timeout bounds time, not memory; a
    /// pathological repo (millions of untracked files) could otherwise stream
    /// unbounded output into one buffer. 512 KB holds every porcelain header plus
    /// far more entries than the dirty count's `+999+` display can distinguish.
    var maxOutputBytes: Int
    private let environment: [String: String]
    private let delay: Delay

    /// The process environment with trusted tool dirs prepended to PATH and the
    /// repo-selection vars scrubbed, computed once. A child may shell out to other
    /// tools; under the launchd environment a bundled `.app` lacks the user's shell
    /// PATH. Trusted absolute dirs go FIRST so a relative/repo-local inherited entry
    /// can't shadow a tool with an attacker-planted binary. `GIT_DIR` /
    /// `GIT_WORK_TREE` / `GIT_INDEX_FILE` are removed so an exported env can't point
    /// git/gh at a different repo than the one we passed as the working directory.
    /// (`ProcessInfo.environment` rebuilds a dict per access, so it must not sit on a
    /// hot path — hence the `static let`.)
    private static let toolAugmentedEnvironment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        let toolPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["PATH"] = environment["PATH"].map { "\(toolPaths):\($0)" } ?? toolPaths
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"] {
            environment.removeValue(forKey: key)
        }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["PAGER"] = "cat"
        return environment
    }()

    /// Resolves the first executable candidate at init (runners are process-wide
    /// `static let`s, so this probes the filesystem once, not per call).
    init(
        executableCandidates: [String],
        timeout: Duration = .seconds(5),
        maxOutputBytes: Int = 512 * 1024,
        environment: [String: String]? = nil,
        delay: @escaping Delay = { try await ContinuousClock().sleep(for: $0) }
    ) {
        executableURL =
            executableCandidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.environment = environment ?? Self.toolAugmentedEnvironment
        self.delay = delay
    }

    func run(arguments: [String], inDirectory directory: String) async -> Data? {
        // Pre-existing Path Bar contract: a clean exit whose output hit the
        // cap still yields the capped buffer (a git-status dirty count
        // saturates the `+999+` display long before 512 KB), not a hard
        // failure — only `runDetailed` callers that need to distinguish
        // truncation from a complete parse see it as a distinct outcome.
        switch await runDetailed(arguments: arguments, inDirectory: directory) {
        case .success(let data), .outputTruncated(let data):
            return data
        default:
            return nil
        }
    }

    func runDetailed(arguments: [String], inDirectory directory: String) async -> BoundedCommandResult {
        guard let executableURL else {
            return .executableNotFound
        }

        let handle = ProcessHandle()
        handle.process.executableURL = executableURL
        handle.process.currentDirectoryURL = URL(fileURLWithPath: directory)
        handle.process.arguments = arguments
        handle.process.environment = environment
        handle.process.standardOutput = handle.stdout
        handle.process.standardError = FileHandle.nullDevice
        handle.process.standardInput = FileHandle.nullDevice

        let timeout = timeout
        let maxOutputBytes = maxOutputBytes
        let delay = delay
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<BoundedCommandResult, Never>) in
                let state = RunState(
                    continuation: continuation,
                    readHandle: handle.stdout.fileHandleForReading,
                    maxBytes: maxOutputBytes
                )

                // Drain stdout continuously so the child can never block on a full
                // pipe (e.g. `git status` in a very dirty repo). An empty chunk is
                // EOF (all write ends closed).
                handle.stdout.fileHandleForReading.readabilityHandler = { fileHandle in
                    let chunk = fileHandle.availableData
                    if chunk.isEmpty {
                        state.markDrained()
                    } else {
                        state.append(chunk)
                    }
                }

                handle.process.terminationHandler = { process in
                    state.markExited(status: process.terminationStatus)
                    // Bounded fallback: if EOF never arrives because a descendant
                    // inherited stdout and holds it open, resume after a short grace
                    // rather than blocking forever. We resolve to nil (not the
                    // partial buffer): without EOF we can't prove the output is
                    // complete, and a silently-undercounted dirty chip is worse than
                    // none. The normal path resumes immediately once EOF + exit
                    // coincide, so this grace only fires in the pathological case.
                    Task {
                        try? await delay(.milliseconds(500))
                        state.resumeUndrainedAsFailureIfExited()
                    }
                }

                do {
                    try handle.process.run()
                    state.registerTimeoutTask(
                        Task {
                            do { try await delay(timeout) } catch { return }
                            state.markTimedOut()
                            handle.terminateIfRunning()  // SIGTERM
                            do { try await delay(.seconds(1)) } catch { return }
                            handle.killIfRunning()  // SIGKILL
                        })
                } catch {
                    state.fail()
                }
            }
        } onCancel: {
            // Own the escalation here too: if a cancelled child ignores SIGTERM,
            // SIGKILL it after a grace so cancellation can't leave it running.
            handle.terminateIfRunning()
            Task {
                try? await delay(.seconds(1))
                handle.killIfRunning()
            }
        }
    }

    /// Single-resume state for one `run`. Coordinates the readability handler
    /// (data + EOF) and the termination handler (exit + status) so the continuation
    /// resumes exactly once: on (exited ∧ EOF) in the normal case, or the bounded
    /// grace fallback otherwise. Lock-guarded; the resume runs outside the lock.
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private let continuation: CheckedContinuation<BoundedCommandResult, Never>
        private let readHandle: FileHandle
        private let maxBytes: Int
        private var buffer = Data()
        private var exited = false
        private var drained = false
        private var exitStatus: Int32?
        private var timedOut = false
        private var truncated = false
        private var resumed = false
        private var timeoutTask: Task<Void, Never>?

        init(
            continuation: CheckedContinuation<BoundedCommandResult, Never>,
            readHandle: FileHandle,
            maxBytes: Int
        ) {
            self.continuation = continuation
            self.readHandle = readHandle
            self.maxBytes = maxBytes
        }

        func append(_ chunk: Data) {
            lock.lock()
            let remaining = max(0, maxBytes - buffer.count)
            if chunk.count > remaining {
                truncated = true
            }
            // Cap accumulation: keep draining the pipe (so the child can't block)
            // but stop growing the buffer. Porcelain headers come first, and the
            // dirty count saturates the `+999+` display long before this, so a
            // capped buffer still yields a correct-enough count.
            if buffer.count < maxBytes {
                buffer.append(chunk.prefix(remaining))
            }
            lock.unlock()
        }

        func markDrained() {
            lock.lock(); drained = true; let resume = readyResumeLocked(); lock.unlock(); resume?()
        }

        func markExited(status: Int32) {
            lock.lock()
            exited = true
            exitStatus = status
            let timeoutTask = timeoutTask
            self.timeoutTask = nil
            let resume = readyResumeLocked()
            lock.unlock()
            timeoutTask?.cancel()
            resume?()
        }

        func markTimedOut() {
            lock.lock()
            timedOut = true
            lock.unlock()
        }

        func registerTimeoutTask(_ task: Task<Void, Never>) {
            lock.lock()
            let cancel = exited || resumed
            if !cancel { timeoutTask = task }
            lock.unlock()
            if cancel { task.cancel() }
        }

        /// Grace fallback: the child exited but stdout never reached EOF (a
        /// descendant holds the pipe). Resolve to nil — an unconfirmed-complete
        /// buffer must not be painted as a real result.
        func resumeUndrainedAsFailureIfExited() {
            lock.lock()
            let resume = exited ? finishLocked(returning: .outputNotDrained) : nil
            lock.unlock()
            resume?()
        }

        func fail() {
            lock.lock()
            let timeoutTask = timeoutTask
            self.timeoutTask = nil
            let resume = finishLocked(returning: .spawnFailure)
            lock.unlock()
            timeoutTask?.cancel()
            resume?()
        }

        /// Resume only when both the child has exited and stdout reached EOF — the
        /// only state where the collected buffer is provably the complete output.
        private func readyResumeLocked() -> (() -> Void)? {
            guard exited, drained else { return nil }
            if timedOut {
                return finishLocked(returning: .timedOut)
            }
            // Exit status takes priority over truncation: a non-zero exit is
            // `nonZeroExit` regardless of how much output it produced first —
            // truncation only recolors an otherwise-CLEAN exit as "capped but
            // usable" rather than "fully parsed."
            guard exitStatus == 0 else {
                return finishLocked(returning: .nonZeroExit(exitStatus ?? -1))
            }
            if truncated {
                return finishLocked(returning: .outputTruncated(buffer))
            }
            return finishLocked(returning: .success(buffer))
        }

        private func finishLocked(returning value: BoundedCommandResult) -> (() -> Void)? {
            guard !resumed else { return nil }
            resumed = true
            let continuation = continuation
            let readHandle = readHandle
            return {
                readHandle.readabilityHandler = nil
                continuation.resume(returning: value)
            }
        }
    }

    /// Boxes the non-Sendable `Process`/`Pipe` so the timeout, drain, and
    /// cancellation closures can reach them across threads. `terminate()`,
    /// `isRunning`, and `kill(2)` are all safe to call off-thread.
    private final class ProcessHandle: @unchecked Sendable {
        let process = Process()
        let stdout = Pipe()

        func terminateIfRunning() {
            if process.isRunning {
                process.terminate()
            }
        }

        func killIfRunning() {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}
