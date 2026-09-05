import Darwin
import Foundation

// MARK: - ProcessCommandRunner

/// Real `CommandRunner` backed by `Process`. Execs the binary directly (no
/// shell), drains stdout and stderr fully so a chatty child can't deadlock on a
/// full pipe, and bounds child execution plus output collection by `timeout`.
/// Timeout/cancellation sends SIGTERM to a live child, escalating to SIGKILL
/// after one second. Collection stops when that child exits or is killed;
/// descendants are not signaled.
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

        // Each reader owns its descriptor until EOF or an explicit stop. A
        // descendant can retain a writer even after the direct child exits.
        let stdoutTask = Task { await execution.stdoutReader.readToEnd() }
        let stderrTask = Task { await execution.stderrReader.readToEnd() }

        let resume = SingleResume()
        let timeoutState = TimeoutState()
        let cancellationState = CancellationState()
        let timeout = timeout
        let delay = delay
        let schedule = schedule
        let spawn = spawn
        let terminateAfterCancellation: @Sendable () -> Void = {
            execution.terminate()
            if !execution.process.isRunning {
                execution.stopReading()
                resume.resume(returning: ())
            }
            cancellationState.armEscalation {
                do { try await delay(.seconds(1)) } catch { return }
                execution.kill()
                execution.stopReading()
                resume.resume(returning: ())
            }
        }

        defer {
            timeoutState.finish()
            cancellationState.finish()
        }

        return try await withTaskCancellationHandler {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    resume.install(continuation)

                    execution.process.terminationHandler = { _ in
                        if timeoutState.didTimeOut || cancellationState.isCancelled {
                            execution.stopReading()
                        }
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
                                    guard timeoutState.claimTimeout(if: { !execution.isComplete }) else {
                                        // Foundation can drop or delay the exit callback. Once
                                        // the child and readers finish, preserve its real result.
                                        if execution.isComplete { resume.resume(returning: ()) }
                                        return
                                    }
                                    execution.terminate()  // SIGTERM
                                    if !execution.process.isRunning {
                                        execution.stopReading()
                                        resume.resume(returning: ())
                                    }
                                    do { try await delay(.seconds(1)) } catch { return }
                                    execution.kill()  // SIGKILL
                                    execution.stopReading()
                                    resume.resume(returning: ())
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
            } catch {
                execution.stopReading()
                _ = await stdoutTask.value
                _ = await stderrTask.value
                throw error
            }

            let stdout = await stdoutTask.value
            let stderr = await stderrTask.value

            timeoutState.finish()

            // Both the exit callback and the bounded fallback resume returning.
            // Without this check a cancelled run would hand back a CommandResult whose
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
        } onCancel: {
            // If spawn is still blocked, didSpawn() starts this escalation once
            // there is a child. Starting the grace before then could waste it on
            // no pid and leave a later TERM-ignoring child running forever.
            if cancellationState.cancel() {
                terminateAfterCancellation()
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

/// Arms the deadline after spawn and keeps it active until child exit and both
/// output readers have completed. Child exit alone does not finish the operation.
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

    func claimTimeout(if operationIsPending: () -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // Foundation may report isRunning=false before delivering its exit
        // callback. Completed output plus an exited child must remain success.
        guard !finished, operationIsPending() else { return false }
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
    let stdoutReader: ProcessCommandOutputReader
    let stderrReader: ProcessCommandOutputReader

    init() {
        stdoutReader = ProcessCommandOutputReader(stdoutPipe.fileHandleForReading)
        stderrReader = ProcessCommandOutputReader(stderrPipe.fileHandleForReading)
    }

    var isComplete: Bool {
        !process.isRunning && stdoutReader.isFinished && stderrReader.isFinished
    }

    func stopReading() {
        stdoutReader.stop()
        stderrReader.stop()
    }

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

// MARK: - ProcessCommandOutputReader

/// The serial queue owns the buffer and descriptor. Cancellation is thread-safe,
/// but only the source's cancellation handler closes the descriptor, after any
/// in-flight read has returned. Each stream has its own queue and drains independently.
final class ProcessCommandOutputReader: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "awesomux.command-output", qos: .utility)
    private let source: DispatchSourceRead
    private var data = Data()
    private var started = false
    private var stopRequested = false
    private let completionLock = NSLock()
    private var finished = false

    var isFinished: Bool { completionLock.withLock { finished } }

    init(_ handle: FileHandle) {
        self.handle = handle
        source = DispatchSource.makeReadSource(fileDescriptor: handle.fileDescriptor, queue: queue)
    }

    func readToEnd() async -> Data {
        await withCheckedContinuation { continuation in
            queue.async {
                let descriptor = self.handle.fileDescriptor
                let flags = fcntl(descriptor, F_GETFL)
                let configured = flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
                self.source.setEventHandler {
                    var buffer = [UInt8](repeating: 0, count: 16_384)
                    let count = Darwin.read(descriptor, &buffer, buffer.count)
                    if count > 0 {
                        self.data.append(contentsOf: buffer.prefix(count))
                    } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                        self.source.cancel()
                    }
                }
                self.source.setCancelHandler {
                    try? self.handle.close()
                    self.source.setEventHandler(handler: nil)
                    self.source.setCancelHandler(handler: nil)
                    self.completionLock.withLock { self.finished = true }
                    continuation.resume(returning: self.data)
                }
                self.started = true
                self.source.activate()
                if self.stopRequested || !configured { self.source.cancel() }
            }
        }
    }

    func stop() {
        queue.async {
            self.stopRequested = true
            if self.started { self.source.cancel() }
        }
    }
}

// MARK: - SingleResume

/// The callback, deadline, cancellation, and spawn failure paths race to release
/// the same wait. The continuation is installed before any spawn is scheduled,
/// so none of those paths can resume it before installation.
private final class SingleResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.withLock { self.continuation = continuation }
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
