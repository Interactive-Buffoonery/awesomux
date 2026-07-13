import Testing
@testable import AwesoMuxCore

@Suite("BridgeSurfaceCommandPolicy")
struct BridgeSurfaceCommandPolicyTests {
    @Test("attaches when the bridge is enabled and an attach command is available")
    func attachesWhenEnabledAndAvailable() {
        #expect(
            BridgeSurfaceCommandPolicy.command(
                bridgeEnabled: true,
                attachCommandAvailable: true
            ) == .bridgeAttach
        )
    }

    @Test("falls back to a local shell when the bridge is disabled")
    func localShellWhenDisabled() {
        #expect(
            BridgeSurfaceCommandPolicy.command(
                bridgeEnabled: false,
                attachCommandAvailable: true
            ) == .localShell
        )
    }

    @Test("falls back to a local shell when no attach command is available")
    func localShellWhenNoAttachCommand() {
        #expect(
            BridgeSurfaceCommandPolicy.command(
                bridgeEnabled: true,
                attachCommandAvailable: false
            ) == .localShell
        )
    }

    @Test("falls back to a local shell when both bridge and attach command are unavailable")
    func localShellWhenDisabledAndNoAttachCommand() {
        #expect(
            BridgeSurfaceCommandPolicy.command(
                bridgeEnabled: false,
                attachCommandAvailable: false
            ) == .localShell
        )
    }

    @Test("a remote group with no attach command is unavailable, not a local shell")
    func remoteGroupWithNoAttachCommandIsUnavailableNotLocalShell() {
        let remotePlan = PaneExecutionPlan.ssh(
            SSHExecution(
                target: RemoteTarget(user: "ed", host: "box")!
            ))
        #expect(
            BridgeSurfaceCommandPolicy.command(
                bridgeEnabled: true, attachCommandAvailable: false, executionPlan: remotePlan
        ) == .remoteUnavailable)
        // Local group unchanged: still falls back to a local shell.
        #expect(
            BridgeSurfaceCommandPolicy.command(
                bridgeEnabled: true, attachCommandAvailable: false, executionPlan: .local
        ) == .localShell)
        // Happy path unchanged.
        #expect(
            BridgeSurfaceCommandPolicy.command(
                bridgeEnabled: true, attachCommandAvailable: true, executionPlan: remotePlan
        ) == .bridgeAttach)
    }

    @Test("a remote group with the bridge globally disabled errors, never a local shell")
    func remoteGroupWithBridgeDisabledIsUnavailableNotLocalShell() {
        let remotePlan = PaneExecutionPlan.ssh(
            SSHExecution(
                target: RemoteTarget(user: "ed", host: "box")!
            ))
        // A disabled bridge means no `amx attach`, so a remote group has no
        // way to reach its host — it must error, not silently spawn a local
        // shell masquerading as the remote (ADR-0022). `isRemote` wins over
        // `bridgeEnabled`.
        #expect(
            BridgeSurfaceCommandPolicy.command(
                bridgeEnabled: false, attachCommandAvailable: false, executionPlan: remotePlan
        ) == .remoteUnavailable)
        // Even if some attach command were somehow available, a disabled
        // bridge can't use it for a remote group — still unavailable.
        #expect(
            BridgeSurfaceCommandPolicy.command(
                bridgeEnabled: false, attachCommandAvailable: true, executionPlan: remotePlan
        ) == .remoteUnavailable)
    }
}
