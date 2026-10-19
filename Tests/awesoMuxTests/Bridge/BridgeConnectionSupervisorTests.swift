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

        let ackLine = try await client.readLine()
        #expect(
            BridgeHandshake.parse(line: ackLine)
                == .helloAck(
                    session: "session", proto: "awesomux-bridge-v1", ts: 42
                ))
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

        let nackLine = try await client.readLine()
        #expect(BridgeHandshake.parse(line: nackLine) == .helloNack(supported: BridgeConnectionSupervisor.supportedProtocols))
        #expect(await client.waitForEOF(timeoutMilliseconds: 10_000))
    }

    @Test(
        "wrong token or session closes without replying",
        arguments: [
            ("wrong-length-token", "session"), ("token", "wrong-session"),
        ])
    func invalidIdentityClosesSilently(token: String, session: String) async throws {
        let actor = try BridgeConnectionActor(expectedToken: "token", expectedSession: "session")
        let recorder = Recorder()
        let supervisor = makeSupervisor(actor: actor, recorder: recorder)
        await supervisor.start()
        defer { Task { await supervisor.shutdown() } }
        let client = try UnixSocketClient(path: actor.socketPath)
        try client.write(
            try BridgeHandshake.hello(
                proto: "awesomux-bridge-v1", token: token, session: session, ts: 1, helper: "test"
            ).encodedLine())
        #expect(await client.waitForEOF(timeoutMilliseconds: 10_000))
        #expect(await recorder.lostConnections.values.isEmpty)
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
        _ = try await oldClient.readLine()

        let newClient = try UnixSocketClient(path: actor.socketPath)
        try newClient.write(helloLine)
        _ = try await newClient.readLine()

        #expect(await oldClient.waitForEOF(timeoutMilliseconds: 10_000))
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
        _ = try await client.readLine()
        client.disconnect()

        #expect(await recorder.lostConnections.waitForCount(1, deadline: .seconds(10)))
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
