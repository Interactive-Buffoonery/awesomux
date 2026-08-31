import Foundation

public struct OpenCodeTranscriptSnapshot: Equatable, Sendable {
    public struct Message: Equatable, Sendable {
        public let id: String
        public let data: Data?
        public let parts: [Part]

        public init(id: String, data: Data?, parts: [Part]) {
            self.id = id
            self.data = data
            self.parts = parts
        }
    }

    public struct Part: Equatable, Sendable {
        public let data: Data?
        public let byteCount: Int

        public init(data: Data?, byteCount: Int) {
            self.data = data
            self.byteCount = byteCount
        }
    }

    public let databaseURL: URL
    public let messages: [Message]
    public let isTruncated: Bool

    public init(databaseURL: URL, messages: [Message], isTruncated: Bool) {
        self.databaseURL = databaseURL
        self.messages = messages
        self.isTruncated = isTruncated
    }
}
