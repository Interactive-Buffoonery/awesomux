import Darwin
import Foundation

public enum AgentHookInputReader {
    public static func read(
        fileDescriptor: Int32,
        maximumByteCount: Int,
        idleTimeoutMilliseconds: Int32
    ) -> Data {
        guard maximumByteCount >= 0 else {
            return Data()
        }

        let targetByteCount = maximumByteCount + 1
        var data = Data()

        while data.count < targetByteCount {
            var pollDescriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            var pollResult: Int32
            repeat {
                pollResult = poll(&pollDescriptor, 1, idleTimeoutMilliseconds)
            } while pollResult < 0 && errno == EINTR

            guard pollResult > 0 else {
                return data
            }

            var buffer = [UInt8](
                repeating: 0,
                count: min(4096, targetByteCount - data.count)
            )
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                var result: Int
                repeat {
                    result = Darwin.read(fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
                } while result < 0 && errno == EINTR
                return result
            }

            guard bytesRead > 0 else {
                return data
            }

            data.append(buffer, count: bytesRead)
        }

        return data
    }
}
