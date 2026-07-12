import Foundation

/// The live exec-channel default for `BridgeAttachPreflight`: runs one
/// already-assembled shell command through `/bin/sh -c`, pipes `stdin` to it
/// (the bridge state file JSON rides here, never argv — spec "Correlation and
/// credential delivery"), captures stdout, and throws on a nonzero exit,
/// timeout, or spawn failure. The command strings come from `AmxBackend`'s
/// bridge builders, which own all quoting; this type only executes them.
///
/// A single type per file that boxes the non-`Sendable` `Process`/`Pipe` trio,
/// mirroring `ProcessCommandRunner`'s termination/timeout escalation so a
/// wedged `ssh` can never pin the attach sequence.
enum BridgeExecChannel {
    enum ExecError: Error, Equatable {
        case spawnFailed
        case nonzeroExit(Int32)
        case timedOut
        case outputTooLarge
    }

    static let maximumOutputByteCount = 64 * 1024

    // Bridge stdin is ≤4 KiB and stdout is tiny (a $HOME line, a
    // stat mode, or nothing) — both well under the 64 KiB pipe buffer, so
    // writing stdin fully before draining stdout cannot deadlock. Revisit
    // (interleave the write with the drain) only if a future exec-channel
    // command has to stream a large payload in either direction.
    static func run(
        command: String,
        stdin: Data?,
        timeout: Duration = .seconds(15)
    ) async throws -> Data {
        // Bail before spawning if this exec was already cancelled (the attach
        // single-flight cancels a superseded run) — otherwise a doomed `ssh`
        // would still launch and pin the restart for up to `timeout`.
        try Task.checkCancellation()
        let execution = ShellExecution()
        execution.process.executableURL = URL(fileURLWithPath: "/bin/sh")
        execution.process.arguments = ["-c", command]
        execution.process.standardInput = execution.stdinPipe
        execution.process.standardOutput = execution.stdoutPipe
        execution.process.standardError = FileHandle.nullDevice

        let outputTooLarge = TimeoutFlag()
        let stdoutTask = Task.detached {
            var output = Data()
            let reader = execution.stdoutPipe.fileHandleForReading
            while let chunk = try? reader.read(upToCount: 8 * 1024), !chunk.isEmpty {
                guard output.count + chunk.count <= maximumOutputByteCount else {
                    outputTooLarge.set()
                    execution.terminate()
                    break
                }
                output.append(chunk)
            }
            return output
        }

        let timedOut = TimeoutFlag()
        let timeoutDuration = timeout

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resume = SingleResume(continuation)

                let timeoutTask = Task {
                    do { try await Task.sleep(for: timeoutDuration) } catch { return }
                    timedOut.set()
                    execution.terminate()
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    execution.kill()
                }

                execution.process.terminationHandler = { _ in
                    timeoutTask.cancel()
                    resume.resume(returning: ())
                }

                do {
                    // Re-check inside the continuation: cancellation landing
                    // between the top-of-function check and here must not spawn
                    // a process the onCancel SIGTERM would only no-op against
                    // (it fires terminate() while the child isn't running yet).
                    if Task.isCancelled {
                        timeoutTask.cancel()
                        try? execution.stdoutPipe.fileHandleForWriting.close()
                        resume.resume(throwing: CancellationError())
                        return
                    }
                    try execution.process.run()
                    // Feed stdin now that the child is consuming it, then close
                    // the write end so a reader (`cat`) sees EOF. Small payloads
                    // only (see the ceiling note above), so this never blocks.
                    let writer = execution.stdinPipe.fileHandleForWriting
                    if let stdin, !stdin.isEmpty {
                        try? writer.write(contentsOf: stdin)
                    }
                    try? writer.close()
                } catch {
                    timeoutTask.cancel()
                    try? execution.stdoutPipe.fileHandleForWriting.close()
                    resume.resume(throwing: ExecError.spawnFailed)
                }
            }
        } onCancel: {
            execution.terminate()
            Task {
                try? await Task.sleep(for: .seconds(1))
                execution.kill()
            }
        }

        let stdout = await stdoutTask.value
        try Task.checkCancellation()

        if timedOut.isSet {
            throw ExecError.timedOut
        }
        if outputTooLarge.isSet {
            throw ExecError.outputTooLarge
        }
        let status = execution.process.terminationStatus
        guard status == 0 else {
            throw ExecError.nonzeroExit(status)
        }
        return stdout
    }
}

/// Boxes the non-`Sendable` `Process`/`Pipe` trio so the timeout and
/// cancellation closures can reach them across threads.
private final class ShellExecution: @unchecked Sendable {
    let process = Process()
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func kill() {
        if process.isRunning { Foundation.kill(process.processIdentifier, SIGKILL) }
    }
}

/// One-shot continuation guard: the run() and terminationHandler paths can both
/// try to resume; only the first wins.
private final class SingleResume: @unchecked Sendable {
    private let continuation: CheckedContinuation<Void, Error>
    private var resumed = false
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Void) {
        lock.lock(); defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock(); defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(throwing: error)
    }
}

/// Thread-safe one-way flag for "the timeout fired."
private final class TimeoutFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }
}
