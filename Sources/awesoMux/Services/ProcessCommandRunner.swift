import Darwin
import Foundation

// MARK: - ProcessCommandRunner

/// Real `CommandRunner` backed by `Process`. Execs the binary directly (no
/// shell), drains stdout and stderr fully so a chatty child can't deadlock on a
/// full pipe, and terminates the process if it overruns `timeout`.
///
/// The environment is built explicitly from a minimal base plus the caller's
/// keys (contract §3): a bundled `.app` inherits launchd's stripped `PATH`, so a
/// trusted default `PATH` is seeded when the caller did not pin one, letting the
/// Claude Node CLI resolve its own sub-tools. Nothing else from the host
/// environment leaks in.
struct ProcessCommandRunner: CommandRunner {
    typealias Delay = @Sendable (Duration) async throws -> Void
    typealias Schedule = @Sendable (@escaping @Sendable () -> Void) -> Void
    typealias Spawn = @Sendable (Process) throws -> Void

    /// Trusted absolute tool dirs, used as the `PATH` of last resort when the
    /// caller did not supply one.
    static var defaultToolPath: String {
        [
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".local/bin", directoryHint: .isDirectory)
                .path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ].joined(separator: ":")
    }

    /// Resolve an executable reference to an on-disk URL, or `nil` if no
    /// executable is found. A reference containing `/` is tilde-expanded and
    /// checked directly; a bare name is searched across the `:`-separated
    /// `searchPath` dirs (each tilde-expanded), first executable match wins.
    ///
    /// Shared by `resolvedExecutableURL` and the Codex app-server transport so the
    /// two spawn paths resolve bare names identically. Callers throw their own
    /// not-found error on `nil` — the resolver stays error-type-agnostic.
    static func resolveExecutable(
        _ reference: String,
        searchPath: String,
        homeDirectoryURL: URL
    ) -> URL? {
        func expandingTilde(_ path: String) -> String {
            if path == "~" {
                return homeDirectoryURL.path
            }
            if path.hasPrefix("~/") {
                return homeDirectoryURL.appending(path: String(path.dropFirst(2))).path
            }
            return path
        }

        if reference.contains("/") {
            let path = expandingTilde(reference)
            return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }

        for rawDirectory in searchPath.split(separator: ":", omittingEmptySubsequences: true) {
            let directory = expandingTilde(String(rawDirectory))
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appending(path: reference)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        return nil
    }

    var timeout: Duration
    private let defaultPath: String
    private let homeDirectoryURL: URL
    private let delay: Delay
    private let schedule: Schedule
    private let spawn: Spawn

    init(
        timeout: Duration = .seconds(30),
        defaultPath: String = ProcessCommandRunner.defaultToolPath,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        delay: @escaping Delay = { try await ContinuousClock().sleep(for: $0) },
        schedule: @escaping Schedule = {
            DispatchQueue.global(qos: .userInitiated).async(execute: $0)
        },
        spawn: @escaping Spawn = { try $0.run() }
    ) {
        self.timeout = timeout
        self.defaultPath = defaultPath
        self.homeDirectoryURL = homeDirectoryURL
        self.delay = delay
        self.schedule = schedule
        self.spawn = spawn
    }

    func run(
        executable: String,
        args: [String],
        env: [String: String],
        cwd: URL?
    ) async throws -> CommandResult {
        try Task.checkCancellation()

        let environment = resolvedEnvironment(env)
        let executableURL = try resolvedExecutableURL(executable: executable, environment: environment)

        let execution = ProcessExecution()
        execution.process.executableURL = executableURL
        execution.process.arguments = args
        execution.process.environment = environment
        if let cwd {
            execution.process.currentDirectoryURL = cwd
        }
        execution.process.standardOutput = execution.stdoutPipe
        execution.process.standardError = execution.stderrPipe

        // Drain both streams to EOF on background threads. Both reads return once
        // the child exits (or is killed on timeout) and the write ends close.
        let stdoutTask = Self.readToEnd(execution.stdoutPipe.fileHandleForReading)
        let stderrTask = Self.readToEnd(execution.stderrPipe.fileHandleForReading)

        let timeoutState = TimeoutState()
        let cancellationState = CancellationState()
        let timeout = timeout
        let delay = delay
        let schedule = schedule
        let spawn = spawn
        let terminateAfterCancellation: @Sendable () -> Void = {
            execution.terminate()
            cancellationState.armEscalation {
                try? await delay(.seconds(1))
                execution.kill()
            }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resume = SingleResume(continuation)

                execution.process.terminationHandler = { _ in
                    timeoutState.finish()
                    cancellationState.finish()
                    resume.resume(returning: ())
                }

                guard !Task.isCancelled, !cancellationState.isCancelled else {
                    _ = cancellationState.cancel()
                    try? execution.stdoutPipe.fileHandleForWriting.close()
                    try? execution.stderrPipe.fileHandleForWriting.close()
                    resume.resume(throwing: CancellationError())
                    return
                }

                schedule {
                    guard !cancellationState.isCancelled else {
                        timeoutState.finish()
                        cancellationState.finish()
                        try? execution.stdoutPipe.fileHandleForWriting.close()
                        try? execution.stderrPipe.fileHandleForWriting.close()
                        resume.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        try spawn(execution.process)
                        if cancellationState.didSpawn(cancelledNow: false) {
                            // Cancellation may arrive while spawn is blocked, when
                            // the cancellation handler has no child to terminate yet.
                            terminateAfterCancellation()
                        } else {
                            timeoutState.arm {
                                do { try await delay(timeout) } catch { return }
                                guard timeoutState.claimTimeout(if: { execution.process.isRunning }) else { return }
                                execution.terminate()  // SIGTERM
                                do { try await delay(.seconds(1)) } catch { return }
                                execution.kill()  // SIGKILL
                            }
                        }
                    } catch {
                        timeoutState.finish()
                        cancellationState.finish()
                        // A failed spawn leaves parent-owned pipe writers open. Close
                        // them before resuming so both drains reach EOF.
                        try? execution.stdoutPipe.fileHandleForWriting.close()
                        try? execution.stderrPipe.fileHandleForWriting.close()
                        if cancellationState.isCancelled {
                            resume.resume(throwing: CancellationError())
                        } else {
                            resume.resume(
                                throwing: CommandRunnerError.spawnFailed(
                                    executable,
                                    reason: error.localizedDescription
                                ))
                        }
                    }
                }
            }
        } onCancel: {
            // If spawn is still blocked, didSpawn() starts this escalation once
            // there is a child. Starting the grace before then could waste it on
            // no pid and leave a later TERM-ignoring child running forever.
            if cancellationState.cancel() {
                terminateAfterCancellation()
            }
        }

        let stdout = await stdoutTask.value
        let stderr = await stderrTask.value

        // A cancelled run reaches here via the termination handler resuming
        // *returning* (onCancel SIGTERM'd the child, which fired the handler).
        // Without this check the function would hand back a CommandResult whose
        // signal-derived non-zero exit is indistinguishable from a present binary
        // that ran and failed — collapsing two of the three failure channels the
        // contract (§3) keeps separate. Cancellation must throw, not return.
        try Task.checkCancellation()

        if timeoutState.didTimeOut {
            throw CommandRunnerError.timedOut(executable, timeout)
        }

        return CommandResult(
            exitCode: execution.process.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
    }

    private static func readToEnd(_ handle: FileHandle) -> Task<Data, Never> {
        Task {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: handle.readDataToEndOfFile())
                }
            }
        }
    }

    /// A minimal base environment plus the caller's keys. `PATH` is always
    /// present (contract §3) so the spawned CLI can resolve its own sub-tools; the
    /// caller's explicit keys (e.g. `CODEX_HOME`, an overriding `PATH`) win.
    private func resolvedEnvironment(_ callerEnv: [String: String]) -> [String: String] {
        var environment: [String: String] = ["PATH": defaultPath]
        for (key, value) in callerEnv {
            environment[key] = value
        }
        return environment
    }

    /// Resolve CLI-absent up front: a missing or non-executable target is the §3
    /// "Unsupported" signal, kept on a different channel from a binary that
    /// spawns and exits non-zero. Checking here also keeps the pipe-drain tasks
    /// from ever blocking on a child that never started.
    private func resolvedExecutableURL(executable: String, environment: [String: String]) throws -> URL {
        guard let url = Self.resolveExecutable(
            executable,
            searchPath: environment["PATH"] ?? "",
            homeDirectoryURL: homeDirectoryURL
        ) else {
            throw CommandRunnerError.executableNotFound(executable)
        }
        return url
    }
}

// MARK: - CancellationState

/// Coordinates cancellation with synchronous spawn. Exactly one side starts
/// termination: cancellation immediately when a child exists, or the spawn path
/// after a cancellation that arrived while no child existed.
private final class CancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var spawned = false
    private var startedTermination = false
    private var escalationTask: Task<Void, Never>?
    private var finished = false

    func cancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        return claimTerminationIfReady()
    }

    func didSpawn(cancelledNow: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        spawned = true
        cancelled = cancelled || cancelledNow
        return claimTerminationIfReady()
    }

    func armEscalation(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        escalationTask = Task { await operation() }
        lock.unlock()
    }

    func finish() {
        lock.lock()
        finished = true
        let escalationTask = escalationTask
        self.escalationTask = nil
        lock.unlock()
        escalationTask?.cancel()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func claimTerminationIfReady() -> Bool {
        guard cancelled, spawned, !startedTermination else { return false }
        startedTermination = true
        return true
    }
}

// MARK: - TimeoutState

/// Arms the timeout only after spawn and coordinates it with immediate process
/// termination. If termination wins the lock before `arm`, no task is created;
/// if the deadline wins, the termination handler preserves that classification.
private final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var finished = false
    private var timedOut = false

    func arm(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        task = Task { await operation() }
        lock.unlock()
    }

    func claimTimeout(if childIsRunning: () -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // Process may have exited before Foundation dispatches its termination
        // handler. Do not let handler latency turn that completed child into a
        // timeout merely because `finished` has not been set yet.
        guard !finished, childIsRunning() else { return false }
        timedOut = true
        return true
    }

    func finish() {
        lock.lock()
        finished = true
        let task = task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }
}

// MARK: - ProcessExecution

/// Boxes the non-`Sendable` `Process`/`Pipe` trio so the timeout, drain, and
/// cancellation closures can reach them across threads. `terminate()`,
/// `isRunning`, and `kill(2)` are all safe to call off-thread.
private final class ProcessExecution: @unchecked Sendable {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }

    func kill() {
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
}

// MARK: - SingleResume

/// Guards a checked continuation against a double resume. The termination handler
/// and the `run()` failure path are mutually exclusive, but the guard keeps the
/// invariant explicit rather than load-bearing on that reasoning.
private final class SingleResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Void) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let continuation = continuation
        self.continuation = nil
        return continuation
    }
}
