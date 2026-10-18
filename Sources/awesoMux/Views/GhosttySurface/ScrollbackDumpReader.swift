import Foundation

enum ScrollbackDumpReader {
    enum Result: Equatable, Sendable {
        case loaded(String)
        case recent(String)
        case tooLarge
        case failed
        case busy
    }

    static func read(
        maximumBytes: Int,
        allowsRecentOutput: Bool = false,
        operation: (UnsafeMutableBufferPointer<UInt8>, inout Int) -> Int32
    ) -> Result {
        guard maximumBytes > 0 else { return .failed }
        var buffer = [UInt8](repeating: 0, count: maximumBytes)
        var written = 0
        let status = buffer.withUnsafeMutableBufferPointer { bytes in
            operation(bytes, &written)
        }
        switch status {
        case 0, 2:
            guard status == 0 || allowsRecentOutput else { return .failed }
            guard written >= 0, written <= buffer.count else { return .failed }
            guard let text = String(bytes: buffer.prefix(written), encoding: .utf8) else { return .failed }
            return status == 2 ? .recent(text) : .loaded(text)
        case 1:
            // A bounded writer may have filled part of the buffer. Never
            // present that prefix as if it were the complete history.
            return .tooLarge
        default:
            return .failed
        }
    }
}
