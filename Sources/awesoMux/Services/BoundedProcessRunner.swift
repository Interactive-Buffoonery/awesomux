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
        let execution = Execution()
        execution.process.executableURL = executableURL
        execution.process.arguments = arguments
        execution.process.standardInput = execution.stdinPipe
        execution.process.standardOutput = execution.stdoutPipe
        execution.process.standardError = FileHandle.nullDevice
        _ = fcntl(execution.stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        do {
            try Task.checkCancellation()
            try execution.process.run()
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
        let waitTask = Task.detached { @Sendable in execution.process.waitUntilExit() }

        await withTaskCancellationHandler {
            await waitTask.value
        } onCancel: {
            execution.terminateThenKill()
        }
        timeoutTimer.cancel()

        let wroteAllBytes = await writerTask.value
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
        guard wroteAllBytes else {
            throw ExecError.inputFailed
        }
        return stdout
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
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()

        func terminate() {
            if process.isRunning { process.terminate() }
        }

        func kill() {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }

        func terminateThenKill() {
            terminate()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) { [self] in
                kill()
            }
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
