import AwesoMuxCore
import Darwin
import Foundation
import Testing
@testable import awesoMux

@Suite("Bridge connection supervisor", .serialized)
struct BridgeConnectionSupervisorTests {
    @Test("valid hello promotes and replies hello-ack")
    func validHelloPromotesAndAcks() async throws {
        let actor = try BridgeConnectionActor(expectedToken: "token", expectedSession: "session")
        let recorder = Recorder()
        let supervisor = makeSupervisor(actor: actor, recorder: recorder)
        await supervisor.start()
        defer { Task { await supervisor.shutdown() } }

        let client = try RawUnixClient(path: actor.socketPath)
        try client.write(helloLine)

        let ackLine = try client.readLine()
        #expect(BridgeHandshake.parse(line: ackLine) == .helloAck(
            session: "session", proto: "awesomux-bridge-v1", ts: 42
        ))
    }

    @Test("unknown proto gets exactly one hello-nack, then closes")
    func unknownProtoNacksThenCloses() async throws {
        let actor = try BridgeConnectionActor(expectedToken: "token", expectedSession: "session")
        let recorder = Recorder()
        let supervisor = makeSupervisor(actor: actor, recorder: recorder)
        await supervisor.start()
        defer { Task { await supervisor.shutdown() } }

        let client = try RawUnixClient(path: actor.socketPath)
        try client.write(try BridgeHandshake.hello(
            proto: "awesomux-bridge-v2", token: "token", session: "session", ts: 1, helper: "test"
        ).encodedLine())

        let nackLine = try client.readLine()
        #expect(BridgeHandshake.parse(line: nackLine) == .helloNack(supported: BridgeConnectionSupervisor.supportedProtocols))
        // The nack is the mandatory, and only, reply — the connection closes
        // right after it, no further bytes.
        #expect(client.waitForEOF(timeoutMilliseconds: 300))
    }

    @Test("unsupported proto still nacks even when the token is also wrong — proto is checked first")
    func unknownProtoTakesPriorityOverOtherFailures() async throws {
        let actor = try BridgeConnectionActor(expectedToken: "token", expectedSession: "session")
        let recorder = Recorder()
        let supervisor = makeSupervisor(actor: actor, recorder: recorder)
        await supervisor.start()
        defer { Task { await supervisor.shutdown() } }

        let client = try RawUnixClient(path: actor.socketPath)
        // Both proto AND token are wrong here — a guard-ordering regression
        // that let a later check short-circuit the mandatory proto rejection
        // would turn this into a silent close instead of a nack.
        try client.write(try BridgeHandshake.hello(
            proto: "awesomux-bridge-v2", token: "also-wrong", session: "session", ts: 1, helper: "test"
        ).encodedLine())

        let nackLine = try client.readLine()
        #expect(BridgeHandshake.parse(line: nackLine) == .helloNack(supported: BridgeConnectionSupervisor.supportedProtocols))
        #expect(client.waitForEOF(timeoutMilliseconds: 300))
    }

    @Test("wrong token closes silently with no reply")
    func wrongTokenClosesSilently() async throws {
        let actor = try BridgeConnectionActor(expectedToken: "token", expectedSession: "session")
        let recorder = Recorder()
        let supervisor = makeSupervisor(actor: actor, recorder: recorder)
        await supervisor.start()
        defer { Task { await supervisor.shutdown() } }

        let client = try RawUnixClient(path: actor.socketPath)
        try client.write(try BridgeHandshake.hello(
            proto: "awesomux-bridge-v1", token: "wrong-length-token", session: "session", ts: 1, helper: "test"
        ).encodedLine())

        // First readable event is EOF itself — no ack, no nack, nothing.
        #expect(client.waitForEOF(timeoutMilliseconds: 300))
        #expect(await recorder.lostConnections.isEmpty)
    }

    @Test("wrong session closes silently with no reply")
    func wrongSessionClosesSilently() async throws {
        let actor = try BridgeConnectionActor(expectedToken: "token", expectedSession: "session")
        let recorder = Recorder()
        let supervisor = makeSupervisor(actor: actor, recorder: recorder)
        await supervisor.start()
        defer { Task { await supervisor.shutdown() } }

        let client = try RawUnixClient(path: actor.socketPath)
        try client.write(try BridgeHandshake.hello(
            proto: "awesomux-bridge-v1", token: "token", session: "wrong-session", ts: 1, helper: "test"
        ).encodedLine())

        #expect(client.waitForEOF(timeoutMilliseconds: 300))
    }

    @Test("a second valid hello replaces the first and fires the connection-lost sink")
    func secondHelloReplacesFirst() async throws {
        let actor = try BridgeConnectionActor(expectedToken: "token", expectedSession: "session")
        let recorder = Recorder()
        let supervisor = makeSupervisor(actor: actor, recorder: recorder)
        await supervisor.start()
        defer { Task { await supervisor.shutdown() } }

        let oldClient = try RawUnixClient(path: actor.socketPath)
        try oldClient.write(helloLine)
        _ = try oldClient.readLine()

        let newClient = try RawUnixClient(path: actor.socketPath)
        try newClient.write(helloLine)
        _ = try newClient.readLine()

        #expect(oldClient.waitForEOF(timeoutMilliseconds: 300))
        try await waitUntil { await recorder.lostConnections.count == 1 }

        // The replacement, not merely a stray extra event: exactly one loss,
        // and it happened for a connection that is no longer the active one —
        // the new client's own frames still make it to the sink below.
        try newClient.write(try envelope(.paneRename(title: "still active"), id: "after-replace").encodedLine())
        try await waitUntil { await recorder.frames.count == 1 }
        #expect(await recorder.lostConnections.count == 1)
    }

    @Test("ordinary active connection EOF fires the connection-lost sink")
    func activeConnectionEOFFiresLoss() async throws {
        let actor = try BridgeConnectionActor(expectedToken: "token", expectedSession: "session")
        let recorder = Recorder()
        let supervisor = makeSupervisor(actor: actor, recorder: recorder)
        await supervisor.start()
        defer { Task { await supervisor.shutdown() } }

        let client = try RawUnixClient(path: actor.socketPath)
        try client.write(helloLine)
        _ = try client.readLine()
        client.disconnect()

        try await waitUntil { await recorder.lostConnections.count == 1 }
    }

    @Test("post-handshake envelopes reach the frame sink generation-tagged; handshake frames never do")
    func envelopeReachesFrameSinkHandshakeNever() async throws {
        let actor = try BridgeConnectionActor(expectedToken: "token", expectedSession: "session")
        let recorder = Recorder()
        let supervisor = makeSupervisor(actor: actor, recorder: recorder)
        await supervisor.start()
        defer { Task { await supervisor.shutdown() } }

        let firstClient = try RawUnixClient(path: actor.socketPath)
        try firstClient.write(helloLine)
        _ = try firstClient.readLine()

        // Give the handshake a beat to (not) leak into the frame sink before
        // any envelope is ever sent.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.frames.isEmpty)

        try firstClient.write(try envelope(.paneRename(title: "first"), id: "first-id").encodedLine())
        try await waitUntil { await recorder.frames.count == 1 }
        let firstGeneration = try #require(await recorder.frames.first?.generation)

        // Replace the connection; the new one's frames carry a different
        // generation than the old one's, proving the tag is per-promotion,
        // not a constant.
        let secondClient = try RawUnixClient(path: actor.socketPath)
        try secondClient.write(helloLine)
        _ = try secondClient.readLine()
        try secondClient.write(try envelope(.paneRename(title: "second"), id: "second-id").encodedLine())
        try await waitUntil { await recorder.frames.count == 2 }

        let secondGeneration = try #require(await recorder.frames.last?.generation)
        #expect(firstGeneration != secondGeneration)
        // Still exactly two frames delivered — no handshake frame ever
        // reached the sink for either connection.
        #expect(await recorder.frames.count == 2)
    }

    @Test("constant-time compare is the one shared implementation, not a second hand-rolled one")
    func constantTimeCompareIsShared() {
        // BridgeConnectionSupervisor's hello token check calls
        // BridgeFrameReader.constantTimeEquals directly (see its doc comment
        // and the `package`-access bump on that function) rather than a
        // second copy — this exercises the exact symbol, not a stand-in, and
        // asserts behavior (not timing, which is inherently flaky in tests).
        #expect(BridgeFrameReader.constantTimeEquals("token", "token"))
        #expect(!BridgeFrameReader.constantTimeEquals("token", "tokfn"))
        #expect(!BridgeFrameReader.constantTimeEquals("token", "shorter"))
        #expect(!BridgeFrameReader.constantTimeEquals("", "nonempty"))
    }

    // MARK: - Helpers

    private func makeSupervisor(actor: BridgeConnectionActor, recorder: Recorder) -> BridgeConnectionSupervisor {
        BridgeConnectionSupervisor(
            connectionActor: actor,
            expectedToken: "token",
            expectedSession: "session",
            wallNow: { Date(timeIntervalSince1970: 42) },
            frameSink: { envelope, generation in await recorder.recordFrame(envelope, generation) },
            connectionLostSink: { connection in await recorder.recordLost(connection) }
        )
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

    private func waitUntil(
        timeout: Duration = .milliseconds(500),
        _ predicate: @escaping () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TestSocketError.timedOut
    }
}

/// Records what the supervisor hands to its two injected sinks. An actor
/// (not a lock-guarded class) because the sinks themselves are called from
/// the supervisor's own isolation — matching that shape is simpler than
/// bridging to a synchronous lock.
private actor Recorder {
    private(set) var frames: [(envelope: BridgeEnvelope, generation: BridgeConnectionActor.Generation)] = []
    private(set) var lostConnections: [BridgeConnectionActor.ConnectionID] = []

    func recordFrame(_ envelope: BridgeEnvelope, _ generation: BridgeConnectionActor.Generation) {
        frames.append((envelope, generation))
    }

    func recordLost(_ connection: BridgeConnectionActor.ConnectionID) {
        lostConnections.append(connection)
    }
}

private enum TestSocketError: Error { case system, closed, timedOut }

/// Minimal raw client, duplicated from `BridgeConnectionActorTests` (that
/// copy is `private` to its own file) rather than shared — small enough that
/// hoisting it into shared test infra isn't worth a third file for one task.
private final class RawUnixClient {
    private let fd: Int32

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestSocketError.system }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw TestSocketError.system }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
        }
        guard result == 0 else { throw TestSocketError.system }
    }

    deinit { Darwin.close(fd) }

    func write(_ line: String) throws {
        let data = Data((line + "\n").utf8)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw TestSocketError.system }
                offset += count
            }
        }
    }

    func disconnect() {
        _ = Darwin.shutdown(fd, SHUT_RDWR)
    }

    /// Blocks up to `timeoutMilliseconds` for the first byte, then reads to
    /// the newline without a further per-byte timeout — the server writes a
    /// whole line in one `write(2)` call, so once bytes start arriving over
    /// loopback the rest follow immediately.
    // The production accept-to-hello budget is five seconds. Keep this test
    // bounded well below that contract while allowing the async supervisor to
    // be scheduled under the full preflight's concurrent test load.
    func readLine(timeoutMilliseconds: Int32 = 2_000) throws -> String {
        guard waitForReadable(timeoutMilliseconds: timeoutMilliseconds) else { throw TestSocketError.timedOut }
        var bytes: [UInt8] = []
        while true {
            var byte: UInt8 = 0
            let count = Darwin.read(fd, &byte, 1)
            guard count == 1 else { throw TestSocketError.closed }
            if byte == 0x0A { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
    }

    func waitForEOF(timeoutMilliseconds: Int32) -> Bool {
        guard waitForReadable(timeoutMilliseconds: timeoutMilliseconds) else { return false }
        var byte: UInt8 = 0
        return Darwin.read(fd, &byte, 1) == 0
    }

    func waitForReadable(timeoutMilliseconds: Int32) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        return Darwin.poll(&descriptor, 1, timeoutMilliseconds) > 0
    }
}
