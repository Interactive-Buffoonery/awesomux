import Foundation
import GhosttyKit

enum GhosttyRuntimeProbe {
    static var linkedVersion: String {
        let info = ghostty_info()

        let bytes = UnsafeBufferPointer(
            start: UnsafeRawPointer(info.version).assumingMemoryBound(to: UInt8.self),
            count: Int(info.version_len)
        )

        return String(decoding: bytes, as: UTF8.self)
    }
}
