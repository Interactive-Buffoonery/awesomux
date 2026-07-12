import Foundation

public struct MarkdownSelfWriteContext: Equatable, Sendable {
    public let source: String
    public let isSelfWrite: Bool

    public init(source: String, isSelfWrite: Bool) {
        self.source = source
        self.isSelfWrite = isSelfWrite
    }
}

public struct MarkdownSelfWriteRegistry: Sendable {
    public static let defaultValidityInterval: TimeInterval = 5

    private let validityInterval: TimeInterval
    private var entries: [String: Entry] = [:]

    public init(validityInterval: TimeInterval = Self.defaultValidityInterval) {
        self.validityInterval = validityInterval
    }

    public mutating func record(fileURL: URL, source: String, now: Date = Date()) {
        entries[Self.key(for: fileURL)] = Entry(source: source, recordedAt: now)
    }

    public mutating func context(
        fileURL: URL,
        onDiskSource: String,
        now: Date = Date()
    ) -> MarkdownSelfWriteContext? {
        let key = Self.key(for: fileURL)
        guard let entry = entries[key] else { return nil }
        guard now.timeIntervalSince(entry.recordedAt) <= validityInterval else {
            entries[key] = nil
            return nil
        }
        return MarkdownSelfWriteContext(
            source: entry.source,
            isSelfWrite: entry.source == onDiskSource
        )
    }

    private static func key(for fileURL: URL) -> String {
        fileURL.standardizedFileURL.path
    }

    private struct Entry: Sendable {
        let source: String
        let recordedAt: Date
    }
}
