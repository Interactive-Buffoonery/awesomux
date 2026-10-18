import Darwin
import Foundation
import Testing
@testable import AwesoMuxAgentHookSupport
import AwesoMuxTestSupport

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
        // Keep the byte-cap contract independent of pipe backpressure and the
        // reader's separate idle-timeout behavior.
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-hook-input")
        defer { withExtendedLifetime(temporaryDirectory) {} }
        let inputData = Data(
            repeating: UInt8(ascii: "x"),
            count: AgentHookCommand.maximumInputByteCount + 10
        )
        let inputURL = temporaryDirectory.url.appending(path: "input.json")
        try inputData.write(to: inputURL)
        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        defer {
            #expect(throws: Never.self) {
                try inputHandle.close()
            }
        }

        let input = AgentHookInputReader.read(
            fileDescriptor: inputHandle.fileDescriptor,
            maximumByteCount: AgentHookCommand.maximumInputByteCount,
            idleTimeoutMilliseconds: 0
        )

        #expect(input.count == AgentHookCommand.maximumInputByteCount + 1)
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var fds = [Int32](repeating: 0, count: 2)
        guard pipe(&fds) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (read: fds[0], write: fds[1])
    }

    private static func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let byteCount = min(4096, rawBuffer.count - offset)
                let bytesWritten = Darwin.write(
                    fileDescriptor,
                    rawBuffer.baseAddress?.advanced(by: offset),
                    byteCount
                )

                if bytesWritten > 0 {
                    offset += bytesWritten
                } else if bytesWritten < 0 && errno == EINTR {
                    continue
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }
}
