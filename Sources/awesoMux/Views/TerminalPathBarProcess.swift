import Darwin
import Foundation

/// Runs a Path Bar status lookup (`git status`, `gh pr view`, `gh run list`) for
/// a repo/branch and returns stdout on success, or nil on any failure (tool
/// missing, non-zero exit, timeout). Injected into the resolvers so tests never
/// shell out.
typealias StatusCommandRunner = @Sendable (_ repoRoot: String, _ branch: String) async -> Data?

/// Outcome of a bounded subprocess run. Callers must choose whether truncated
/// stdout is acceptable (prefix-safe chips) or must fail closed (authoritative
/// lists / existence checks).
enum BoundedCommandResult: Sendable, Equatable {
    case complete(Data)
    case truncated(prefix: Data)
    case failed

    /// Fail-closed: only fully collected successful stdout.
    var completeData: Data? {
        if case .complete(let data) = self { return data }
        return nil
    }

    /// Prefix-safe: complete or truncated prefix after a clean exit + EOF.
    var dataAllowingTruncation: Data? {
        switch self {
        case .complete(let data), .truncated(let data):
            return data
        case .failed:
            return nil
        }
    }
}

/// Runs a bounded external command and returns an explicit stdout result on a
/// clean exit (status 0), or `.failed` on any failure (executable missing,
/// non-zero exit, timeout, undrained pipe). Shared by the Path Bar's `gh` (PR)
/// and `git` (status) lookups.
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

    func run(arguments: [String], inDirectory directory: String) async -> BoundedCommandResult {
        guard let executableURL else {
            return .failed
        }

        let handle = ProcessHandle()
        handle.process.executableURL = executableURL
        handle.process.currentDirectoryURL = URL(fileURLWithPath: directory)
        handle.process.arguments = arguments
        handle.process.environment = environment
        handle.process.standardOutput = handle.stdout
        handle.process.standardError = FileHandle.nullDevice

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
                    state.markExited(success: process.terminationStatus == 0)
                    // Bounded fallback: if EOF never arrives because a descendant
                    // inherited stdout and holds it open, resume after a short grace
                    // rather than blocking forever. We resolve to `.failed` (not the
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
            // Detach so the grace Task does not inherit this cancelled context
            // (an inherited-cancelled Task would skip the delay and may race
            // the kill before the test/harness observes the grace path).
            handle.terminateIfRunning()
            Task.detached {
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
        private var truncated = false
        private var exited = false
        private var drained = false
        private var success = false
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
            // Cap accumulation: keep draining the pipe (so the child can't block)
            // but stop growing the buffer past `maxBytes`, and record truncation
            // so callers never treat a prefix as complete output.
            if buffer.count >= maxBytes {
                truncated = true
            } else {
                let remaining = maxBytes - buffer.count
                if chunk.count <= remaining {
                    buffer.append(chunk)
                } else {
                    buffer.append(chunk.prefix(remaining))
                    truncated = true
                }
            }
            lock.unlock()
        }

        func markDrained() {
            lock.lock(); drained = true; let resume = readyResumeLocked(); lock.unlock(); resume?()
        }

        func markExited(success: Bool) {
            lock.lock()
            exited = true
            self.success = success
            let timeoutTask = timeoutTask
            self.timeoutTask = nil
            let resume = readyResumeLocked()
            lock.unlock()
            timeoutTask?.cancel()
            resume?()
        }

        func registerTimeoutTask(_ task: Task<Void, Never>) {
            lock.lock()
            let cancel = exited || resumed
            if !cancel { timeoutTask = task }
            lock.unlock()
            if cancel { task.cancel() }
        }

        /// Grace fallback: the child exited but stdout never reached EOF (a
        /// descendant holds the pipe). Resolve to `.failed` — an unconfirmed-
        /// complete buffer must not be painted as a real result.
        func resumeUndrainedAsFailureIfExited() {
            lock.lock()
            let resume = exited ? finishLocked(returning: .failed) : nil
            lock.unlock()
            resume?()
        }

        func fail() {
            lock.lock()
            let timeoutTask = timeoutTask
            self.timeoutTask = nil
            let resume = finishLocked(returning: .failed)
            lock.unlock()
            timeoutTask?.cancel()
            resume?()
        }

        /// Resume only when both the child has exited and stdout reached EOF — the
        /// only state where the collected buffer's completeness is known.
        private func readyResumeLocked() -> (() -> Void)? {
            guard exited, drained else { return nil }
            guard success else {
                return finishLocked(returning: .failed)
            }
            if truncated {
                return finishLocked(returning: .truncated(prefix: buffer))
            }
            return finishLocked(returning: .complete(buffer))
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
