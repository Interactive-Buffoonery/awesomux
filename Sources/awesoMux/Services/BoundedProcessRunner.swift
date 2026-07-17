import Darwin
import Dispatch
import Foundation

enum BoundedProcessRunner {
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
        timeout: DispatchTimeInterval
    ) async throws -> Data {
        try Task.checkCancellation()
        let execution: Execution
        do {
            try Task.checkCancellation()
            execution = try Execution(executableURL: executableURL, arguments: arguments)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExecError.spawnFailed
        }

        let outputTooLarge = Flag()
        let stdoutTask = Task.detached { @Sendable in
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

        let writerTask = Task.detached { @Sendable in
            let wroteAllBytes = write(input, to: execution.stdinPipe.fileHandleForWriting.fileDescriptor)
            try? execution.stdinPipe.fileHandleForWriting.close()
            return wroteAllBytes
        }
        let timedOut = Flag()
        let timeoutTimer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timeoutTimer.schedule(deadline: .now() + timeout)
        timeoutTimer.setEventHandler {
            timedOut.set()
            execution.terminateThenKill()
        }
        timeoutTimer.resume()
        let waitTask = Task.detached { @Sendable in execution.waitForExit() }

        let result = await withTaskCancellationHandler {
            let status = await waitTask.value
            let wroteAllBytes = await writerTask.value
            let stdout = await stdoutTask.value
            execution.markPipesFinished()
            return (status: status, wroteAllBytes: wroteAllBytes, stdout: stdout)
        } onCancel: {
            execution.terminateThenKill()
        }
        timeoutTimer.cancel()

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
        private var processID: pid_t = 0
        private var pipesFinished = false
        private var terminationStarted = false

        init(executableURL: URL, arguments: [String]) throws {
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
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) { [self] in
                lock.lock()
                let shouldKill = !pipesFinished
                lock.unlock()
                guard shouldKill else { return }
                Darwin.kill(-processID, SIGKILL)
            }
        }

        func markPipesFinished() {
            lock.lock()
            pipesFinished = true
            lock.unlock()
        }
    }

    private final class Flag: @unchecked Sendable {
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
}
