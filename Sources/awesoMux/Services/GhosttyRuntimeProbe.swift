import Foundation
import GhosttyKit

enum GhosttyRuntimeProbe {
    static var linkedVersion: String {
        let info = ghostty_info()

        guard let version = info.version else {
            return "unknown"
        }

        let bytes = UnsafeBufferPointer(
            start: UnsafeRawPointer(version).assumingMemoryBound(to: UInt8.self),
            count: Int(info.version_len)
        )

        return String(decoding: bytes, as: UTF8.self)
    }
}
