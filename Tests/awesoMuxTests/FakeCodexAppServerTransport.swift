import Foundation
@testable import awesoMux

final class FakeCodexAppServerTransport: CodexAppServerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [Data] = []
    private var incoming: [Data] = []

    var sentMessages: [Data] { lock.withLock { sent } }

    func enqueueResponse(_ json: String) {
        lock.withLock { incoming.append(Data(json.utf8)) }
    }

    func send(_ message: Data) async throws {
        lock.withLock { sent.append(message) }
    }

    func receive() async throws -> Data? {
        lock.withLock { incoming.isEmpty ? nil : incoming.removeFirst() }
    }

    func close() {}
}
