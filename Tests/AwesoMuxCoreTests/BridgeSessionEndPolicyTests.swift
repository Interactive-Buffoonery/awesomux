import Testing
@testable import AwesoMuxCore

@Suite("BridgeSessionEndPolicy")
struct BridgeSessionEndPolicyTests {
    @Test(arguments: [
        (nil as String?, true, false, nil as Int?, 0, "respawnFresh"),
        ("unknown", true, false, nil, 0, "respawnFresh"),
        ("shellExit", true, false, nil, 0, "markExited"),
        ("shellExit", true, true, 0, 0, "markExited"),
        ("shellExit", true, true, 255, 0, "error"),
        ("shellExit", true, true, 1, 0, "markExited"),
        ("shellExit", true, true, nil, 0, "error"),
        ("shellExit", true, false, 255, 0, "markExited"),
        ("daemonDied", true, false, nil, 0, "respawnFresh"),
        ("detached", true, false, nil, 0, "reconnect"),
        ("daemonDied", true, false, nil, 3, "error"),
        ("daemonDied", false, false, nil, 0, "markExited"),
        ("daemonDied", false, true, nil, 0, "error"),
    ])
    func sessionEndDecision(reason: String?, enabled: Bool, remote: Bool, exitCode: Int?, attempts: Int, expected: String) throws {
        let reasons: [String: SessionEndReason] = [
            "unknown": .unknown, "shellExit": .shellExit, "daemonDied": .daemonDied, "detached": .detached,
        ]
        let endReason = try reason.map { try #require(reasons[$0]) }
        let commands: [String: BridgeSessionEndCommand] = [
            "respawnFresh": .respawnFresh, "markExited": .markExited, "reconnect": .reconnect, "error": .error,
        ]
        let command = try #require(commands[expected])
        #expect(
            BridgeSessionEndPolicy.decide(
                reason: endReason, bridgeEnabled: enabled,
                isRemote: remote, exitCode: exitCode, respawnAttempts: attempts, maxAttempts: 3) == command)
    }
}
