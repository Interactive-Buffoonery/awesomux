import Foundation
import Testing
import AwesoMuxBridgeProtocol
@testable import AwesoMuxBridgeHelperSupport

@Suite
struct BridgeHelperCommandTests {

    @Test("foreground-liveness validates arguments and writes one bounded JSON object")
    func foregroundLivenessSuccess() throws {
        var probedSession: String?
        var lines: [String] = []
        let status = BridgeHelperCommand.run(
            arguments: ["foreground-liveness", "--session", "session-1"],
            probeLiveness: { session in
                probedSession = session
                return .init(state: .idleShell, comm: "zsh", hasChildren: false)
            },
            output: { lines.append($0) },
            errorOutput: { _ in Issue.record("unexpected stderr write") }
        )
        #expect(status == 0)
        #expect(probedSession == "session-1")
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        #expect(line.utf8.count <= RemoteForegroundLivenessReport.maximumEncodedByteCount)
        let report = try JSONDecoder().decode(
            RemoteForegroundLivenessReport.self,
            from: Data(line.utf8)
        )
        #expect(report == .init(state: .idleShell, comm: "zsh", hasChildren: false))
        #expect(throws: EncodingError.self) {
            try RemoteForegroundLivenessReport(
                state: .liveCommand,
                comm: String(repeating: "x", count: 600)
            ).encoded()
        }
    }

    @Test("foreground-liveness probe failure writes only stderr")
    func foregroundLivenessFailure() {
        struct ProbeFailure: Error {}
        var errors: [String] = []
        let status = BridgeHelperCommand.run(
            arguments: ["foreground-liveness", "--session", "session-1"],
            probeLiveness: { _ in throw ProbeFailure() },
            output: { _ in Issue.record("unexpected stdout write") },
            errorOutput: { errors.append($0) }
        )
        #expect(status == 1)
        #expect(errors == ["awesoMuxBridgeHelper: liveness probe failed"])
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

}
