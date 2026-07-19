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

    init(
        timeout: Duration = .seconds(30),
        defaultPath: String = ProcessCommandRunner.defaultToolPath,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.timeout = timeout
        self.defaultPath = defaultPath
        self.homeDirectoryURL = homeDirectoryURL
    }

    func run(
        executable: String,
        args: [String],
        env: [String: String],
        cwd: URL?
    ) async throws -> CommandResult {
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
        let stdoutTask = Task.detached {
            execution.stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrTask = Task.detached {
            execution.stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        let timedOut = OneShotFlag()
        let timeout = timeout

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resume = SingleResume(continuation)

                let timeoutTask = Task {
                    // A cancelled sleep means the child already exited (the
                    // termination handler cancels this task); never signal a
                    // dead/recycled pid.
                    do { try await Task.sleep(for: timeout) } catch { return }
                    timedOut.set()
                    execution.terminate() // SIGTERM
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    execution.kill() // SIGKILL
                }

                execution.process.terminationHandler = { _ in
                    timeoutTask.cancel()
                    resume.resume(returning: ())
                }

                do {
                    try execution.process.run()
                } catch {
                    timeoutTask.cancel()
                    // run() failed after the existence check passed: unblock the
                    // drain tasks by closing the write ends we still hold, then
                    // report a spawn failure distinct from a missing binary.
                    try? execution.stdoutPipe.fileHandleForWriting.close()
                    try? execution.stderrPipe.fileHandleForWriting.close()
                    resume.resume(throwing: CommandRunnerError.spawnFailed(
                        executable,
                        reason: error.localizedDescription
                    ))
                }
            }
        } onCancel: {
            // Own the escalation here too: a cancelled child that ignores SIGTERM
            // is SIGKILL'd after a grace so cancellation can't leave it running.
            execution.terminate()
            Task {
                try? await Task.sleep(for: .seconds(1))
                execution.kill()
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

        if timedOut.isSet {
            throw CommandRunnerError.timedOut(executable, timeout)
        }

        return CommandResult(
            exitCode: execution.process.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
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
