import Darwin
import Foundation
import Testing
@testable import AwesoMuxAgentHookSupport

@Suite
struct AgentHookInputReaderTests {
    @Test
    func returnsSmallPayloadWithoutWaitingForEOFAfterIdleTimeout() throws {
        let pipe = try Self.makePipe()
        defer {
            close(pipe.read)
            close(pipe.write)
        }

        let payload = Data(#"{"hook_event_name":"SessionStart"}"#.utf8)
        try Self.writeAll(payload, to: pipe.write)

        let input = AgentHookInputReader.read(
            fileDescriptor: pipe.read,
            maximumByteCount: AgentHookCommand.maximumInputByteCount,
            idleTimeoutMilliseconds: 25
        )

        #expect(input == payload)
    }

    @Test
    func stopsAfterMaximumPlusOneBytes() throws {
        let pipe = try Self.makePipe()
        defer {
            close(pipe.read)
        }

        let inputData = Data(
            repeating: UInt8(ascii: "x"),
            count: AgentHookCommand.maximumInputByteCount + 10
        )
        let firstWriteCompleted = DispatchSemaphore(value: 0)
        let writeFinished = DispatchGroup()
        writeFinished.enter()
        DispatchQueue.global().async {
            var didSignalFirstWrite = false
            defer {
                if !didSignalFirstWrite {
                    firstWriteCompleted.signal()
                }
                close(pipe.write)
                writeFinished.leave()
            }

            try? Self.writeAll(inputData, to: pipe.write) {
                didSignalFirstWrite = true
                firstWriteCompleted.signal()
            }
        }
        firstWriteCompleted.wait()

        let input = AgentHookInputReader.read(
            fileDescriptor: pipe.read,
            maximumByteCount: AgentHookCommand.maximumInputByteCount,
            idleTimeoutMilliseconds: 25
        )

        #expect(input.count == AgentHookCommand.maximumInputByteCount + 1)
        try Self.drainUntilEOF(from: pipe.read)
        writeFinished.wait()
    }

    @Test
    func emptyOpenPipeReturnsEmptyAfterTimeout() throws {
        let pipe = try Self.makePipe()
        defer {
            close(pipe.read)
            close(pipe.write)
        }

        let input = AgentHookInputReader.read(
            fileDescriptor: pipe.read,
            maximumByteCount: AgentHookCommand.maximumInputByteCount,
            idleTimeoutMilliseconds: 25
        )

        #expect(input.isEmpty)
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var fds = [Int32](repeating: 0, count: 2)
        guard pipe(&fds) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (read: fds[0], write: fds[1])
    }

    private static func writeAll(
        _ data: Data,
        to fileDescriptor: Int32,
        afterFirstWrite: (() -> Void)? = nil
    ) throws {
        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            var didNotifyFirstWrite = false
            while offset < rawBuffer.count {
                let byteCount = min(4096, rawBuffer.count - offset)
                let bytesWritten = Darwin.write(
                    fileDescriptor,
                    rawBuffer.baseAddress?.advanced(by: offset),
                    byteCount
                )

                if bytesWritten > 0 {
                    offset += bytesWritten
                    if !didNotifyFirstWrite {
                        didNotifyFirstWrite = true
                        afterFirstWrite?()
                    }
                } else if bytesWritten < 0 && errno == EINTR {
                    continue
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    private static func drainUntilEOF(from fileDescriptor: Int32) throws {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if bytesRead == 0 {
                return
            } else if bytesRead > 0 {
                continue
            } else if errno == EINTR {
                continue
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }
}
