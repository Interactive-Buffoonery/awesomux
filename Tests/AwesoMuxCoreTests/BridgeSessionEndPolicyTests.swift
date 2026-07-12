import Testing
@testable import AwesoMuxCore

@Suite("BridgeSessionEndPolicy")
struct BridgeSessionEndPolicyTests {
    @Test("respawns fresh when reason is nil (fail-safe)")
    func failSafeRespawnsWhenReasonAbsent() {
        #expect(BridgeSessionEndPolicy.decide(reason: nil, bridgeEnabled: true, respawnAttempts: 0, maxAttempts: 3) == .respawnFresh)
    }

    @Test("respawns fresh when reason is unknown (fail-safe)")
    func failSafeRespawnsWhenReasonUnknown() {
        #expect(BridgeSessionEndPolicy.decide(reason: .unknown, bridgeEnabled: true, respawnAttempts: 0, maxAttempts: 3) == .respawnFresh)
    }

    @Test("marks exited when shell exits")
    func shellExitMarksExited() {
        #expect(BridgeSessionEndPolicy.decide(reason: .shellExit, bridgeEnabled: true, respawnAttempts: 0, maxAttempts: 3) == .markExited)
    }

    @Test("remote clean exit (code 0) closes the pane like a local shell")
    func remoteCleanShellExitMarksExited() {
        #expect(BridgeSessionEndPolicy.decide(reason: .shellExit, bridgeEnabled: true, isRemote: true, exitCode: 0, respawnAttempts: 0, maxAttempts: 3) == .markExited)
    }

    @Test("remote ssh transport failure (code 255) latches error")
    func remoteTransportFailureShellExitErrors() {
        #expect(BridgeSessionEndPolicy.decide(reason: .shellExit, bridgeEnabled: true, isRemote: true, exitCode: 255, respawnAttempts: 0, maxAttempts: 3) == .error)
    }

    @Test("remote deliberate non-zero exit (e.g. `exit 1`) closes like a local shell")
    func remoteDeliberateNonzeroShellExitCloses() {
        #expect(BridgeSessionEndPolicy.decide(reason: .shellExit, bridgeEnabled: true, isRemote: true, exitCode: 1, respawnAttempts: 0, maxAttempts: 3) == .markExited)
    }

    @Test("remote shell exit with unknown/absent code errors (safe default)")
    func remoteUnknownCodeShellExitErrors() {
        #expect(BridgeSessionEndPolicy.decide(reason: .shellExit, bridgeEnabled: true, isRemote: true, respawnAttempts: 0, maxAttempts: 3) == .error)
    }

    @Test("local shell exit closes regardless of exit code")
    func localShellExitMarksExitedIgnoringCode() {
        #expect(BridgeSessionEndPolicy.decide(reason: .shellExit, bridgeEnabled: true, isRemote: false, exitCode: 255, respawnAttempts: 0, maxAttempts: 3) == .markExited)
    }

    @Test("respawns fresh when daemon dies")
    func daemonDiedRespawns() {
        #expect(BridgeSessionEndPolicy.decide(reason: .daemonDied, bridgeEnabled: true, respawnAttempts: 0, maxAttempts: 3) == .respawnFresh)
    }

    @Test("reconnects when detached")
    func detachedReconnects() {
        #expect(BridgeSessionEndPolicy.decide(reason: .detached, bridgeEnabled: true, respawnAttempts: 0, maxAttempts: 3) == .reconnect)
    }

    @Test("errors when over respawn limit")
    func overLimitErrors() {
        #expect(BridgeSessionEndPolicy.decide(reason: .daemonDied, bridgeEnabled: true, respawnAttempts: 3, maxAttempts: 3) == .error)
    }

    @Test("marks exited when bridge is disabled")
    func disabledMarksExited() {
        #expect(BridgeSessionEndPolicy.decide(reason: .daemonDied, bridgeEnabled: false, respawnAttempts: 0, maxAttempts: 3) == .markExited)
    }

    @Test("remote bridge disabled latches error instead of closing")
    func remoteDisabledErrors() {
        #expect(BridgeSessionEndPolicy.decide(reason: .daemonDied, bridgeEnabled: false, isRemote: true, respawnAttempts: 0, maxAttempts: 3) == .error)
    }
}
