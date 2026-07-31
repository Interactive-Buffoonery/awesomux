import Darwin
import Dispatch
import Foundation

enum BoundedProcessRunner {
    /// Test-only seam over the waits this runner performs — the overall timeout and
    /// the SIGTERM-to-SIGKILL escalation. A test can stall one, both, or neither by
    /// discriminating on the duration it is handed, which is what lets it assert
    /// which of two competing terminations fired without racing a real clock.
    ///
    /// Deliberately optional, and deliberately not the production path. When it is
    /// nil the waits run on `DispatchSource`/`DispatchQueue`, which cannot be starved
    /// by blocked cooperative-pool threads. A timeout is the mechanism that stops a
    /// wedged child hanging the caller; routing it through the cooperative pool would
    /// make the hang guard itself starvable, which is a worse failure than the
    /// scheduling flake the seam exists to remove.
    typealias Delay = @Sendable (Duration) async throws -> Void

    /// How long a terminated child has to honour SIGTERM before SIGKILL follows.
    /// Exposed so tests can recognise the escalation wait by its duration.
    static let terminationEscalation: Duration = .seconds(1)

    enum ExecError: Error, Equatable {
        case spawnFailed
        case nonzeroExit(Int32)
        case timedOut
        case outputTooLarge
        case inputFailed
    }

    enum Input: Sendable {
        case data(Data)
        case descriptor(Int32, byteCount: Int)
    }

    static func run(
        executableURL: URL,
        arguments: [String],
        input: Input,
        maximumOutputByteCount: Int,
        timeout: Duration,
        delay: Delay? = nil
    ) async throws -> Data {
        try Task.checkCancellation()
        let execution: Execution
        do {
            try Task.checkCancellation()
            execution = try Execution(
                executableURL: executableURL,
                arguments: arguments,
                delay: delay
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExecError.spawnFailed
        }

        let outputTooLarge = OneShotFlag()
        let stdoutTask = Task.detached { @Sendable in
            await runBlocking {
                var output = Data()
                let reader = execution.stdoutPipe.fileHandleForReading
                while let chunk = try? reader.read(upToCount: 8 * 1024), !chunk.isEmpty {
                    guard output.count + chunk.count <= maximumOutputByteCount else {
                        outputTooLarge.set()
                        execution.terminateThenKill()
                        break
                    }
                    output.append(chunk)
                }
                return output
            }
        }

        let writerTask = Task.detached { @Sendable in
            await runBlocking {
                let wroteAllBytes = write(input, to: execution.stdinPipe.fileHandleForWriting.fileDescriptor)
                try? execution.stdinPipe.fileHandleForWriting.close()
                return wroteAllBytes
            }
        }
        // Armed only after the spawn above succeeded, so a slow launch cannot eat the
        // budget. Production stays on a `DispatchSource` timer: it fires from a
        // Dispatch queue that blocked cooperative-pool threads cannot starve, which
        // is exactly what a hang guard needs. Tests supply `delay` to take control of
        // when — or whether — it fires.
        let timedOut = OneShotFlag()
        let fireTimeout = { @Sendable in
            timedOut.set()
            execution.terminateThenKill()
        }
        // Built only on the branch that resumes it: a `DispatchSource` starts
        // suspended, and releasing one that was never resumed traps in libdispatch.
        var timeoutTimer: DispatchSourceTimer?
        var timeoutTask: Task<Void, Never>?
        if let delay {
            timeoutTask = Task.detached { @Sendable in
                do { try await delay(timeout) } catch { return }
                fireTimeout()
            }
        } else {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timer.schedule(deadline: .now() + dispatchInterval(timeout))
            timer.setEventHandler(handler: fireTimeout)
            timer.resume()
            timeoutTimer = timer
        }
        let waitTask = Task.detached { @Sendable in
            await runBlocking { execution.waitForExit() }
        }

        let result = await withTaskCancellationHandler {
            let status = await waitTask.value
            let wroteAllBytes = await writerTask.value
            let stdout = await stdoutTask.value
            execution.markPipesFinished()
            return (status: status, wroteAllBytes: wroteAllBytes, stdout: stdout)
        } onCancel: {
            execution.terminateThenKill()
        }
        timeoutTimer?.cancel()
        timeoutTask?.cancel()

        try Task.checkCancellation()

        if timedOut.isSet {
            throw ExecError.timedOut
        }
        if outputTooLarge.isSet {
            throw ExecError.outputTooLarge
        }
        guard result.status == 0 else {
            throw ExecError.nonzeroExit(result.status)
        }
        guard result.wroteAllBytes else {
            throw ExecError.inputFailed
        }
        return result.stdout
    }

    /// `DispatchTime` has no `+` for `Duration`, and the Dispatch paths above are the
    /// ones that must keep working when the cooperative pool is jammed.
    fileprivate static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = duration.components
        return .nanoseconds(Int(seconds * 1_000_000_000 + attoseconds / 1_000_000_000))
    }

    private static func runBlocking<Result: Sendable>(
        _ operation: @escaping @Sendable () -> Result
    ) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: operation())
            }
        }
    }

    private static func write(_ input: Input, to outputFD: Int32) -> Bool {
        switch input {
        case .data(let data):
            return data.withUnsafeBytes { bytes in
                write(bytes: bytes, byteCount: bytes.count, to: outputFD)
            }
        case .descriptor(let descriptor, let byteCount):
            var offset: off_t = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while offset < byteCount {
                let amount = min(buffer.count, byteCount - Int(offset))
                let bytesRead = buffer.withUnsafeMutableBytes {
                    pread(descriptor, $0.baseAddress, amount, offset)
                }
                if bytesRead < 0, errno == EINTR { continue }
                guard bytesRead > 0,
                    buffer.withUnsafeBytes({ write(bytes: $0, byteCount: bytesRead, to: outputFD) })
                else {
                    return false
                }
                offset += off_t(bytesRead)
            }
            return true
        }
    }

    private static func write(bytes: UnsafeRawBufferPointer, byteCount: Int, to outputFD: Int32) -> Bool {
        var offset = 0
        while offset < byteCount {
            let result = Darwin.write(outputFD, bytes.baseAddress!.advanced(by: offset), byteCount - offset)
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { return false }
            offset += result
        }
        return true
    }

    private final class Execution: @unchecked Sendable {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        private let lock = NSLock()
        private let delay: Delay?
        private var processID: pid_t = 0
        private var pipesFinished = false
        private var terminationStarted = false

        init(executableURL: URL, arguments: [String], delay: Delay?) throws {
            self.delay = delay
            var fileActions: posix_spawn_file_actions_t? = nil
            guard posix_spawn_file_actions_init(&fileActions) == 0 else {
                throw ExecError.spawnFailed
            }
            defer { posix_spawn_file_actions_destroy(&fileActions) }

            let stdinRead = stdinPipe.fileHandleForReading.fileDescriptor
            let stdinWrite = stdinPipe.fileHandleForWriting.fileDescriptor
            let stdoutRead = stdoutPipe.fileHandleForReading.fileDescriptor
            let stdoutWrite = stdoutPipe.fileHandleForWriting.fileDescriptor
            guard posix_spawn_file_actions_adddup2(&fileActions, stdinRead, STDIN_FILENO) == 0,
                posix_spawn_file_actions_adddup2(&fileActions, stdoutWrite, STDOUT_FILENO) == 0,
                posix_spawn_file_actions_addopen(
                    &fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0
                ) == 0,
                [stdinRead, stdinWrite, stdoutRead, stdoutWrite].allSatisfy({
                    posix_spawn_file_actions_addclose(&fileActions, $0) == 0
                })
            else {
                throw ExecError.spawnFailed
            }

            var attributes: posix_spawnattr_t? = nil
            guard posix_spawnattr_init(&attributes) == 0 else {
                throw ExecError.spawnFailed
            }
            defer { posix_spawnattr_destroy(&attributes) }
            guard
                posix_spawnattr_setflags(
                    &attributes, Int16(POSIX_SPAWN_SETPGROUP)
                ) == 0,
                posix_spawnattr_setpgroup(&attributes, 0) == 0
            else {
                throw ExecError.spawnFailed
            }

            let argumentStorage = ([executableURL.path] + arguments).map { strdup($0) }
            guard argumentStorage.allSatisfy({ $0 != nil }) else {
                argumentStorage.forEach { free($0) }
                throw ExecError.spawnFailed
            }
            defer { argumentStorage.forEach { free($0) } }
            var argumentVector = argumentStorage + [nil]
            var spawnedPID: pid_t = 0
            let spawnStatus = argumentVector.withUnsafeMutableBufferPointer { vector in
                posix_spawn(
                    &spawnedPID,
                    executableURL.path,
                    &fileActions,
                    &attributes,
                    vector.baseAddress!,
                    environ
                )
            }
            guard spawnStatus == 0 else { throw ExecError.spawnFailed }
            processID = spawnedPID

            try? stdinPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            _ = fcntl(stdinWrite, F_SETNOSIGPIPE, 1)
        }

        func waitForExit() -> Int32 {
            var status: Int32 = 0
            while waitpid(processID, &status, 0) < 0 {
                if errno == EINTR { continue }
                return -1
            }
            if status & 0x7f == 0 {
                return (status >> 8) & 0xff
            }
            return 128 + (status & 0x7f)
        }

        func terminateThenKill() {
            lock.lock()
            guard !pipesFinished, !terminationStarted else {
                lock.unlock()
                return
            }
            terminationStarted = true
            lock.unlock()

            Darwin.kill(-processID, SIGTERM)
            let escalate = { @Sendable [self] in
                guard stillRunning() else { return }
                Darwin.kill(-processID, SIGKILL)
            }
            // Same reasoning as the timeout: the default path stays on Dispatch so a
            // wedged child is always reaped, even when the cooperative pool is jammed.
            guard let delay else {
                DispatchQueue.global(qos: .userInitiated)
                    .asyncAfter(
                        deadline: .now() + BoundedProcessRunner.dispatchInterval(terminationEscalation),
                        execute: escalate
                    )
                return
            }
            Task.detached { @Sendable in
                do { try await delay(terminationEscalation) } catch { return }
                escalate()
            }
        }

        /// Kept synchronous because `NSLock` cannot be taken from an async context.
        private func stillRunning() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return !pipesFinished
        }

        func markPipesFinished() {
            lock.lock()
            pipesFinished = true
            lock.unlock()
        }
    }
}
