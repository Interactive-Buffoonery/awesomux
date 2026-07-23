import Foundation
import Testing
import AwesoMuxBridgeProtocol
@testable import AwesoMuxBridgeHelperSupport

@Suite
struct BridgeHelperCommandTests {

    @Test
    func versionPrintsSupportedProtocols() {
        var lines: [String] = []
        let status = BridgeHelperCommand.run(
            arguments: ["--version"],
            output: { lines.append($0) },
            errorOutput: { _ in Issue.record("unexpected stderr write") }
        )
        #expect(status == 0)
        #expect(lines == BridgeHelperCommand.supportedProtocols)
        #expect(lines.contains("awesomux-bridge-v1"))
        #expect(lines.contains("awesomux-handoff-v1"))
    }

    @Test
    func selfCheckCustodyFailureIsOneTerseError() {
        var errors: [String] = []
        let status = BridgeHelperCommand.run(
            arguments: ["--self-check"],
            environment: [
                "AWESOMUX_BRIDGE_STATE": "/missing",
                "AWESOMUX_BRIDGE_SESSION": "session",
            ],
            readState: { _ in nil },
            output: { _ in Issue.record("unexpected stdout write") },
            errorOutput: { errors.append($0) }
        )
        #expect(status == BridgeHelperCommand.SelfCheckExit.unavailable)
        #expect(errors == ["awesoMuxBridgeHelper: bridge unavailable"])
        #expect(!errors[0].contains("token"))
    }

    @Test
    func emitCustodyFailureIsSilentUnavailable() {
        let status = BridgeHelperCommand.run(
            arguments: ["--emit", "/missing-fixture"],
            environment: [:],
            output: { _ in Issue.record("unexpected stdout write") },
            errorOutput: { _ in Issue.record("unexpected stderr write") }
        )
        #expect(status == 0)
    }

    @Test(arguments: ["future-v2", "awesomux-handoff-v1"])
    func selfCheckRejectsUnsupportedStateProtocolBeforeConnecting(proto: String) {
        var connected = false
        var errors: [String] = []
        let status = BridgeHelperCommand.run(
            arguments: ["--self-check"],
            environment: ["AWESOMUX_BRIDGE_STATE": "/state", "AWESOMUX_BRIDGE_SESSION": "session"],
            readState: { _ in BridgeStateFile(proto: proto, gen: 1, socket: "/socket", token: "secret") },
            connect: { _, _ in
                connected = true; throw HelperConnection.ConnectionError.connectFailed
            },
            errorOutput: { errors.append($0) }
        )
        #expect(status == BridgeHelperCommand.SelfCheckExit.incompatibleProtocol)
        #expect(!connected)
        #expect(errors == ["awesoMuxBridgeHelper: incompatible protocol"])
    }

    @Test
    func bareInvocationExitsZeroSilently() {
        let status = BridgeHelperCommand.run(
            arguments: [],
            output: { _ in Issue.record("unexpected stdout write") },
            errorOutput: { _ in Issue.record("unexpected stderr write") }
        )
        #expect(status == 0)
    }

    @Test("receive-handoff strictly parses arguments and emits one receipt")
    func receiveHandoffParsesAndEmitsReceipt() {
        var received: (String, String, Int)?
        var output: [String] = []
        let status = BridgeHelperCommand.run(
            arguments: [
                "receive-handoff", "--session", "session-1", "--name", "notes.md",
                "--expected-bytes", "12",
            ],
            receiveHandoff: { session, name, bytes in
                received = (session, name, bytes)
                return .init(path: "/home/me/.awesomux/handoffs/session-1/notes.md", bytes: bytes)
            },
            output: { output.append($0) },
            errorOutput: { _ in Issue.record("unexpected stderr write") }
        )
        #expect(status == 0)
        #expect(received?.0 == "session-1")
        #expect(received?.1 == "notes.md")
        #expect(received?.2 == 12)
        #expect(output.count == 1)
        let receipt = output.first.flatMap { try? JSONDecoder().decode(HandoffReceiver.Receipt.self, from: Data($0.utf8)) }
        #expect(receipt == .init(path: "/home/me/.awesomux/handoffs/session-1/notes.md", bytes: 12))
    }

    @Test(
        "receive-handoff rejects malformed and oversized byte counts",
        arguments: [
            "-1", "+1", "1x", "10485761",
        ])
    func receiveHandoffRejectsInvalidCounts(count: String) {
        var errors: [String] = []
        let status = BridgeHelperCommand.run(
            arguments: [
                "receive-handoff", "--session", "session-1", "--name", "notes.md",
                "--expected-bytes", count,
            ],
            receiveHandoff: { _, _, _ in
                Issue.record("invalid arguments must not reach receiver")
                return .init(path: "/unreachable", bytes: 0)
            },
            output: { _ in Issue.record("unexpected stdout write") },
            errorOutput: { errors.append($0) }
        )
        #expect(status == 64)
        #expect(errors == ["awesoMuxBridgeHelper: invalid handoff arguments"])
    }

    @Test(
        "receive-handoff rejects malformed command shapes before invoking the receiver",
        arguments: [
            ["receive-handoff"],
            [
                "receive-handoff", "--session", "session-1", "--name", "notes.md",
                "--expected-bytes", "12", "extra",
            ],
            [
                "receive-handoff", "--name", "notes.md", "--session", "session-1",
                "--expected-bytes", "12",
            ],
            [
                "receive-handoff", "--sessions", "session-1", "--name", "notes.md",
                "--expected-bytes", "12",
            ],
            [
                "receive-handoff", "--session", "session-1", "--filename", "notes.md",
                "--expected-bytes", "12",
            ],
            [
                "receive-handoff", "--session", "session-1", "--name", "notes.md",
                "--bytes", "12",
            ],
            [
                "receive-handoff", "--session", "Session-1", "--name", "notes.md",
                "--expected-bytes", "12",
            ],
            [
                "receive-handoff", "--session", "session-1", "--name", "",
                "--expected-bytes", "12",
            ],
        ])
    func receiveHandoffRejectsMalformedCommand(arguments: [String]) {
        var errors: [String] = []
        let status = BridgeHelperCommand.run(
            arguments: arguments,
            receiveHandoff: { _, _, _ in
                Issue.record("invalid arguments must not reach receiver")
                return .init(path: "/unreachable", bytes: 0)
            },
            output: { _ in Issue.record("unexpected stdout write") },
            errorOutput: { errors.append($0) }
        )
        #expect(status == 64)
        #expect(errors == ["awesoMuxBridgeHelper: invalid handoff arguments"])
    }
}
