enum ScrollbackDumpReader {
    enum Result: Equatable, Sendable {
        case loaded(String)
        case tooLarge
        case failed
        case busy
    }

    static func read(
        maximumBytes: Int,
        operation: (UnsafeMutableBufferPointer<UInt8>, inout Int) -> Int32
    ) -> Result {
        guard maximumBytes > 0 else { return .failed }
        var buffer = [UInt8](repeating: 0, count: maximumBytes)
        var written = 0
        let status = buffer.withUnsafeMutableBufferPointer { bytes in
            operation(bytes, &written)
        }
        switch status {
        case 0:
            guard written >= 0, written <= buffer.count else { return .failed }
            return .loaded(String(decoding: buffer.prefix(written), as: UTF8.self))
        case 1:
            // A bounded writer may have filled part of the buffer. Never
            // present that prefix as if it were the complete history.
            return .tooLarge
        default:
            return .failed
        }
    }
}
