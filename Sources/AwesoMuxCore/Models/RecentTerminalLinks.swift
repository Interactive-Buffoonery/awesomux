import Foundation

public struct RecentTerminalLinks: Sendable {
    public static let maximumCount = 20
    public static let maximumUTF8ByteCount = 8_192

    public private(set) var values: [String]

    public init(values: [String] = []) {
        self.values = []
        for value in values.reversed() {
            record(value)
        }
    }

    @discardableResult
    public mutating func record(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= Self.maximumUTF8ByteCount else {
            return false
        }
        if let existingIndex = values.firstIndex(of: value) {
            guard existingIndex != 0 else { return false }
            values.remove(at: existingIndex)
        }
        values.insert(value, at: 0)
        if values.count > Self.maximumCount {
            values.removeLast(values.count - Self.maximumCount)
        }
        return true
    }
}
