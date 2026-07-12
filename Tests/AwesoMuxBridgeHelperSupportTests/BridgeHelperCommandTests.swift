import Testing
import AwesoMuxCore
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
    }

    @Test
    func selfCheckCustodyFailureIsOneTerseError() {
        var errors: [String] = []
        let status = BridgeHelperCommand.run(
            arguments: ["--self-check"],
            environment: [
                "AWESOMUX_BRIDGE_STATE": "/missing",
                "AWESOMUX_BRIDGE_SESSION": "session"
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

    @Test
    func selfCheckRejectsUnsupportedStateProtocolBeforeConnecting() {
        var connected = false
        var errors: [String] = []
        let status = BridgeHelperCommand.run(
            arguments: ["--self-check"],
            environment: ["AWESOMUX_BRIDGE_STATE": "/state", "AWESOMUX_BRIDGE_SESSION": "session"],
            readState: { _ in BridgeStateFile(proto: "future-v2", gen: 1, socket: "/socket", token: "secret") },
            connect: { _, _ in connected = true; throw HelperConnection.ConnectionError.connectFailed },
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
}
