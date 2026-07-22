import AwesoMuxBridgeProtocol
import AwesoMuxCore
import AwesoMuxTestSupport
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

        let client = try UnixSocketClient(path: actor.socketPath)
        try client.write(helloLine)

        let ackLine = try client.readLine()
        #expect(
            BridgeHandshake.parse(line: ackLine)
                == .helloAck(
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

        let client = try UnixSocketClient(path: actor.socketPath)
        try client.write(
            try BridgeHandshake.hello(
                proto: "awesomux-bridge-v2", token: "token", session: "session", ts: 1, helper: "test"
            ).encodedLine())

        let nackLine = try client.readLine()
        #expect(BridgeHandshake.parse(line: nackLine) == .helloNack(supported: BridgeConnectionSupervisor.supportedProtocols))
        // The nack is the mandatory, and only, reply — the connection closes
        // right after it, no further bytes.
        #expect(client.waitForEOF(timeoutMilliseconds: 10_000))
    }

    @Test("unsupported proto still nacks even when the token is also wrong — proto is checked first")
    func unknownProtoTakesPriorityOverOtherFailures() async throws {
        let actor = try BridgeConnectionActor(expectedToken: "token", expectedSession: "session")
        let recorder = Recorder()
        let supervisor = makeSupervisor(actor: actor, recorder: recorder)
        await supervisor.start()
        defer { Task { await supervisor.shutdown() } }

        let client = try UnixSocketClient(path: actor.socketPath)
        // Both proto AND token are wrong here — a guard-ordering regression
        // that let a later check short-circuit the mandatory proto rejection
        // would turn this into a silent close instead of a nack.
        try client.write(
            try BridgeHandshake.hello(
                proto: "awesomux-bridge-v2", token: "also-wrong", session: "session", ts: 1, helper: "test"
            ).encodedLine())

        let nackLine = try client.readLine()
        #expect(BridgeHandshake.parse(line: nackLine) == .helloNack(supported: BridgeConnectionSupervisor.supportedProtocols))
        #expect(client.waitForEOF(timeoutMilliseconds: 10_000))
    }

    @Test("wrong token closes silently with no reply")
    func wrongTokenClosesSilently() async throws {
        let actor = try BridgeConnectionActor(expectedToken: "token", expectedSession: "session")
        let recorder = Recorder()
        let supervisor = makeSupervisor(actor: actor, recorder: recorder)
        await supervisor.start()
        defer { Task { await supervisor.shutdown() } }

        let client = try UnixSocketClient(path: actor.socketPath)
        try client.write(
            try BridgeHandshake.hello(
                proto: "awesomux-bridge-v1", token: "wrong-length-token", session: "session", ts: 1, helper: "test"
            ).encodedLine())

        // First readable event is EOF itself — no ack, no nack, nothing.
        #expect(client.waitForEOF(timeoutMilliseconds: 10_000))
        #expect(await recorder.lostConnections.values.isEmpty)
    }

    @Test("wrong session closes silently with no reply")
    func wrongSessionClosesSilently() async throws {
        let actor = try BridgeConnectionActor(expectedToken: "token", expectedSession: "session")
        let recorder = Recorder()
        let supervisor = makeSupervisor(actor: actor, recorder: recorder)
        await supervisor.start()
        defer { Task { await supervisor.shutdown() } }

        let client = try UnixSocketClient(path: actor.socketPath)
        try client.write(
            try BridgeHandshake.hello(
                proto: "awesomux-bridge-v1", token: "token", session: "wrong-session", ts: 1, helper: "test"
            ).encodedLine())

        #expect(client.waitForEOF(timeoutMilliseconds: 10_000))
    }

    @Test("a second valid hello replaces the first and fires the connection-lost sink")
    func secondHelloReplacesFirst() async throws {
        let actor = try BridgeConnectionActor(expectedToken: "token", expectedSession: "session")
        let recorder = Recorder()
        let supervisor = makeSupervisor(actor: actor, recorder: recorder)
        await supervisor.start()
        defer { Task { await supervisor.shutdown() } }

        let oldClient = try UnixSocketClient(path: actor.socketPath)
        try oldClient.write(helloLine)
        _ = try oldClient.readLine()

        let newClient = try UnixSocketClient(path: actor.socketPath)
        try newClient.write(helloLine)
        _ = try newClient.readLine()

        #expect(oldClient.waitForEOF(timeoutMilliseconds: 10_000))
        #expect(await recorder.lostConnections.waitForCount(1, deadline: .seconds(10)))

        // The replacement, not merely a stray extra event: exactly one loss,
        // and it happened for a connection that is no longer the active one —
        // the new client's own frames still make it to the sink below.
        try newClient.write(try envelope(.paneRename(title: "still active"), id: "after-replace").encodedLine())
        #expect(await recorder.frames.waitForCount(1, deadline: .seconds(10)))
        #expect(await recorder.lostConnections.values.count == 1)
    }

    @Test("ordinary active connection EOF fires the connection-lost sink")
    func activeConnectionEOFFiresLoss() async throws {
        let actor = try BridgeConnectionActor(expectedToken: "token", expectedSession: "session")
        let recorder = Recorder()
        let supervisor = makeSupervisor(actor: actor, recorder: recorder)
        await supervisor.start()
        defer { Task { await supervisor.shutdown() } }

        let client = try UnixSocketClient(path: actor.socketPath)
        try client.write(helloLine)
        _ = try client.readLine()
        client.disconnect()

        #expect(await recorder.lostConnections.waitForCount(1, deadline: .seconds(10)))
    }

    @Test("post-handshake envelopes reach the frame sink generation-tagged; handshake frames never do")
    func envelopeReachesFrameSinkHandshakeNever() async throws {
        let actor = try BridgeConnectionActor(expectedToken: "token", expectedSession: "session")
        let recorder = Recorder()
        let supervisor = makeSupervisor(actor: actor, recorder: recorder)
        await supervisor.start()
        defer { Task { await supervisor.shutdown() } }

        let firstClient = try UnixSocketClient(path: actor.socketPath)
        try firstClient.write(helloLine)
        _ = try firstClient.readLine()

        // Give the handshake a beat to (not) leak into the frame sink before
        // any envelope is ever sent.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.frames.values.isEmpty)

        try firstClient.write(try envelope(.paneRename(title: "first"), id: "first-id").encodedLine())
        #expect(await recorder.frames.waitForCount(1, deadline: .seconds(10)))
        let firstGeneration = try #require(await recorder.frames.values.first?.generation)

        // Replace the connection; the new one's frames carry a different
        // generation than the old one's, proving the tag is per-promotion,
        // not a constant.
        let secondClient = try UnixSocketClient(path: actor.socketPath)
        try secondClient.write(helloLine)
        _ = try secondClient.readLine()
        try secondClient.write(try envelope(.paneRename(title: "second"), id: "second-id").encodedLine())
        #expect(await recorder.frames.waitForCount(2, deadline: .seconds(10)))

        let secondGeneration = try #require(await recorder.frames.values.last?.generation)
        #expect(firstGeneration != secondGeneration)
        // Still exactly two frames delivered — no handshake frame ever
        // reached the sink for either connection.
        #expect(await recorder.frames.values.count == 2)
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
            frameSink: { envelope, generation in
                await recorder.frames.record(RecordedFrame(envelope: envelope, generation: generation))
            },
            connectionLostSink: { connection in await recorder.lostConnections.record(connection) }
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

}

private struct RecordedFrame: Sendable {
    let envelope: BridgeEnvelope
    let generation: BridgeConnectionActor.Generation
}

private struct Recorder: Sendable {
    let frames = EventRecorder<RecordedFrame>()
    let lostConnections = EventRecorder<BridgeConnectionActor.ConnectionID>()
}
