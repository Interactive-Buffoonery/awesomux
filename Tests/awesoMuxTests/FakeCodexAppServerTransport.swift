import Foundation
@testable import awesoMux

// MARK: - FakeCodexAppServerTransport

/// In-memory `CodexAppServerTransport` for exercising the JSON-RPC framing and
/// id-correlation in `ProcessCodexAppServerClient` with no real process. Records
/// every `send`, and serves queued responses FIFO from `receive`; an empty queue
/// reads as EOF (`nil`), which drives the `connectionClosed` path.
final class FakeCodexAppServerTransport: CodexAppServerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [Data] = []
    private var incoming: [Data] = []
    private var closed = false
    private var blocksReceive = false
    private var blocksReceiveUntilClosed = false
    private var blockedReceives: [CheckedContinuation<Data?, Never>] = []

    /// When set, `receive` parks indefinitely (until cancelled) instead of
    /// serving the queue or reading EOF — modelling a server that accepts a
    /// request and then goes silent without closing its stdout.
    func blockReceiveForever() {
        lock.withLock { blocksReceive = true }
    }

    /// Model the real stdio transport's pre-fix behavior: task cancellation alone
    /// does not complete `receive`; only tearing down the transport does.
    func blockReceiveUntilClosed() {
        lock.withLock { blocksReceiveUntilClosed = true }
    }

    var sentMessages: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// Queue a raw response line (already-serialized JSON) to be returned by a
    /// later `receive`.
    func enqueueResponse(_ data: Data) {
        lock.lock()
        incoming.append(data)
        lock.unlock()
    }

    func enqueueResponse(_ json: String) {
        enqueueResponse(Data(json.utf8))
    }

    func send(_ message: Data) async throws {
        lock.withLock { sent.append(message) }
    }

    func receive() async throws -> Data? {
        if lock.withLock({ blocksReceiveUntilClosed }) {
            return await withCheckedContinuation { continuation in
                let shouldResumeNow = lock.withLock {
                    if closed {
                        return true
                    }
                    blockedReceives.append(continuation)
                    return false
                }
                if shouldResumeNow {
                    continuation.resume(returning: nil)
                }
            }
        }
        if lock.withLock({ blocksReceive }) {
            // Park until the awaiting task is cancelled (e.g. by the request
            // deadline); never deliver a line or EOF.
            try await Task.sleep(for: .seconds(3600))
            return nil
        }
        return lock.withLock {
            incoming.isEmpty ? nil : incoming.removeFirst()
        }
    }

    func close() {
        let receives = lock.withLock {
            closed = true
            let receives = blockedReceives
            blockedReceives.removeAll()
            return receives
        }
        for receive in receives {
            receive.resume(returning: nil)
        }
    }
}
