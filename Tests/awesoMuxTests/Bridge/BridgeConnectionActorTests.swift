import AwesoMuxBridgeProtocol
import AwesoMuxCore
import AwesoMuxTestSupport
import Darwin
import Foundation
import Testing
@testable import awesoMux

@Suite("Bridge connection actor", .serialized)
struct BridgeConnectionActorTests {
    @Test("bind creates a fresh private directory and owner-only socket")
    func bindCreatesPrivateFreshPaths() async throws {
        let first = try BridgeConnectionActor(expectedToken: "token", expectedSession: "session")
        let second = try BridgeConnectionActor(expectedToken: "token", expectedSession: "session")
        defer {
            Task {
                await first.shutdown()
                await second.shutdown()
            }
        }

        let firstPath = first.socketPath
        let secondPath = second.socketPath
        #expect((firstPath as NSString).deletingLastPathComponent != (secondPath as NSString).deletingLastPathComponent)
        #expect(permissions(of: (firstPath as NSString).deletingLastPathComponent) == 0o700)
        #expect(permissions(of: firstPath) == 0o600)
    }

    @Test("path budget violation fails closed and removes the fresh directory")
    func pathBudgetViolationFailsClosed() throws {
        let temporaryDirectory = try TemporaryDirectory(prefix: "bridge-path-budget")
        let parent = temporaryDirectory.url
        defer { withExtendedLifetime(temporaryDirectory) {} }
        let template = parent.appendingPathComponent("listener-XXXXXX").path

        #expect(throws: BridgeListenerDirectory.DirectoryError.socketPathTooLong) {
            _ = try BridgeListenerDirectory.create(
                socketName: String(repeating: "x", count: 104),
                directoryTemplate: template
            )
        }
        #expect((try FileManager.default.contentsOfDirectory(atPath: parent.path)).isEmpty)
    }

    @Test("accept-to-hello deadline closes a squatter and frees its slot")
    func helloDeadlineClosesAndFreesSlot() async throws {
        let actor = try BridgeConnectionActor(
            expectedToken: "token", expectedSession: "session", helloDeadline: 0.05
        )
        await actor.start()
        defer { Task { await actor.shutdown() } }
        let squatter = try UnixSocketClient(path: actor.socketPath)
        #expect(squatter.waitForEOF(timeoutMilliseconds: 10_000))

        let replacement = try UnixSocketClient(path: actor.socketPath)
        try replacement.write(helloLine)
        let delivery = try await nextFrame(from: actor.frames, timeout: .seconds(10))
        #expect(
            delivery.frame
                == .handshake(
                    .hello(
                        proto: "awesomux-bridge-v1", token: "token", session: "session", ts: 1, helper: "test"
                    )))
    }

    @Test("bogus hello is closed at the deadline and frees its slot")
    func bogusHelloDeadlineClosesAndFreesSlot() async throws {
        let actor = try BridgeConnectionActor(
            expectedToken: "token", expectedSession: "session", helloDeadline: 0.05
        )
        await actor.start()
        defer { Task { await actor.shutdown() } }
        let squatter = try UnixSocketClient(path: actor.socketPath)
        try squatter.write(
            try BridgeHandshake.hello(
                proto: "awesomux-bridge-v1", token: "bogus", session: "session", ts: 1, helper: "test"
            ).encodedLine())
        _ = try await nextFrame(from: actor.frames)

        #expect(squatter.waitForEOF(timeoutMilliseconds: 10_000))

        let replacement = try UnixSocketClient(path: actor.socketPath)
        try replacement.write(helloLine)
        let delivery = try await nextFrame(from: actor.frames, timeout: .seconds(10))
        #expect(
            delivery.frame
                == .handshake(
                    .hello(
                        proto: "awesomux-bridge-v1", token: "token", session: "session", ts: 1, helper: "test"
                    )))
    }

    @Test("second handshake frame closes the connection")
    func secondHandshakeFrameClosesConnection() async throws {
        let actor = try BridgeConnectionActor(expectedToken: "token", expectedSession: "session")
        await actor.start()
        defer { Task { await actor.shutdown() } }
        let client = try UnixSocketClient(path: actor.socketPath)
        try client.write(helloLine)
        _ = try await nextFrame(from: actor.frames)

        try client.write(helloLine)

        #expect(client.waitForEOF(timeoutMilliseconds: 10_000))
    }

    @Test("inbound hello ack closes the connection")
    func inboundHelloAckClosesConnection() async throws {
        let actor = try BridgeConnectionActor(expectedToken: "token", expectedSession: "session")
        await actor.start()
        defer { Task { await actor.shutdown() } }
        let client = try UnixSocketClient(path: actor.socketPath)

        try client.write(
            try BridgeHandshake.helloAck(
                session: "session", proto: "awesomux-bridge-v1", ts: 1
            ).encodedLine())

        #expect(client.waitForEOF(timeoutMilliseconds: 10_000))
    }

    @Test("a non-hello first frame closes the connection")
    func nonHelloFirstFrameClosesConnection() async throws {
        let actor = try BridgeConnectionActor(expectedToken: "token", expectedSession: "session")
        await actor.start()
        defer { Task { await actor.shutdown() } }
        let client = try UnixSocketClient(path: actor.socketPath)
        try client.write(try envelope(.paneRename(title: "premature"), id: "before-hello").encodedLine())

        #expect(client.waitForEOF(timeoutMilliseconds: 10_000))
    }

    @Test("connection cap allows one active plus one handshaking")
    func connectionCapIsHonored() async throws {
        let actor = try BridgeConnectionActor(expectedToken: "token", expectedSession: "session")
        await actor.start()
        defer { Task { await actor.shutdown() } }

        let active = try UnixSocketClient(path: actor.socketPath)
        try active.write(helloLine)
        let activeHello = try await nextFrame(from: actor.frames)
        _ = try #require(await actor.promoteToActive(activeHello.connection) != nil)

        let handshaking = try UnixSocketClient(path: actor.socketPath)
        try handshaking.write(helloLine)
        _ = try await nextFrame(from: actor.frames)

        let refused = try UnixSocketClient(path: actor.socketPath)
        #expect(refused.waitForEOF(timeoutMilliseconds: 10_000))
    }

    @Test("app surfaces inbound permission-resolved and drops app→helper decisions")
    func directionAllowlist() async throws {
        let actor = try BridgeConnectionActor(expectedToken: "token", expectedSession: "session")
        await actor.start()
        defer { Task { await actor.shutdown() } }
        let client = try UnixSocketClient(path: actor.socketPath)
        try client.write(helloLine)
        let hello = try await nextFrame(from: actor.frames)
        _ = await actor.promoteToActive(hello.connection)

        // `permission-decision` is app→helper: an inbound one is misdirected and
        // must be dropped — it never surfaces on `frames`.
        try client.write(
            try envelope(
                .permissionDecision(
                    PermissionDecision(inReplyTo: "request", decision: .allow, scope: .once, target: "build")
                ), id: "wrong"
            ).encodedLine())
        // `permission-resolved` is helper→app (spec): it MUST surface so E1's
        // `handleHelperResolved` can tear the prompt down. Regression guard for
        // the C1 allowlist fix (INT-698 D4 — it was previously dropped inbound).
        let resolved = envelope(
            .permissionResolved(
                PermissionResolved(inReplyTo: "request", reason: .expired)
            ), id: "resolved")
        try client.write(try resolved.encodedLine())
        let rename = envelope(.paneRename(title: "Backend"), id: "right")
        try client.write(try rename.encodedLine())

        // Single fd → in-order reads. The dropped decision never appears, so the
        // first surfaced frame is the resolved (admitted), then the rename.
        let firstDelivery = try await nextFrame(from: actor.frames)
        #expect(firstDelivery.frame == .envelope(resolved))
        let secondDelivery = try await nextFrame(from: actor.frames)
        #expect(secondDelivery.frame == .envelope(rename))
    }

    @Test("replacement closes the old fd and stale generation writes are dropped")
    func replacementAndStaleWrite() async throws {
        let actor = try BridgeConnectionActor(expectedToken: "token", expectedSession: "session")
        await actor.start()
        defer { Task { await actor.shutdown() } }

        let oldClient = try UnixSocketClient(path: actor.socketPath)
        try oldClient.write(helloLine)
        let oldHello = try await nextFrame(from: actor.frames)
        let first = try #require(await actor.promoteToActive(oldHello.connection))

        let newClient = try UnixSocketClient(path: actor.socketPath)
        try newClient.write(helloLine)
        let newHello = try await nextFrame(from: actor.frames)
        let second = try #require(await actor.promoteToActive(newHello.connection))

        #expect(second.replacedConnection == oldHello.connection)
        #expect(second.generation != first.generation)
        #expect(oldClient.waitForEOF(timeoutMilliseconds: 10_000))
        #expect(await actor.send(.helloAck(session: "session", proto: "awesomux-bridge-v1", ts: 2), generation: first.generation) == false)
        #expect(newClient.waitForReadable(timeoutMilliseconds: 50) == false)
        #expect(await actor.send(.helloAck(session: "session", proto: "awesomux-bridge-v1", ts: 2), generation: second.generation))
        #expect(
            BridgeHandshake.parse(line: try newClient.readLine())
                == .helloAck(
                    session: "session", proto: "awesomux-bridge-v1", ts: 2
                ))
    }

    @Test("shutdown closes connections, unlinks the socket, and removes the directory")
    func shutdownRemovesExactPaths() async throws {
        let actor = try BridgeConnectionActor(expectedToken: "token", expectedSession: "session")
        await actor.start()
        let socketPath = actor.socketPath
        let directoryPath = (socketPath as NSString).deletingLastPathComponent
        let client = try UnixSocketClient(path: socketPath)

        await actor.shutdown()

        #expect(client.waitForEOF(timeoutMilliseconds: 10_000))
        #expect(!FileManager.default.fileExists(atPath: socketPath))
        #expect(!FileManager.default.fileExists(atPath: directoryPath))
    }

    private var helloLine: String {
        get throws {
            try BridgeHandshake.hello(
                proto: "awesomux-bridge-v1", token: "token", session: "session", ts: 1, helper: "test"
            ).encodedLine()
        }
    }

    private func envelope(_ message: BridgeMessage, id: String) -> BridgeEnvelope {
        BridgeEnvelope(token: "token", session: "session", id: id, ts: 1, message: message)
    }

    private func permissions(of path: String) -> Int16? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.posixPermissions] as? NSNumber)?.int16Value
    }

    private func nextFrame(
        from stream: AsyncStream<BridgeConnectionActor.FrameDelivery>,
        timeout: Duration = .seconds(10)
    ) async throws -> BridgeConnectionActor.FrameDelivery {
        try await withThrowingTaskGroup(of: BridgeConnectionActor.FrameDelivery.self) { group in
            group.addTask {
                for await delivery in stream { return delivery }
                throw TestSocketError.closed
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TestSocketError.timedOut
            }
            let delivery = try await group.next()!
            group.cancelAll()
            return delivery
        }
    }
}

private enum TestSocketError: Error { case system, closed, timedOut, invalidLine }
