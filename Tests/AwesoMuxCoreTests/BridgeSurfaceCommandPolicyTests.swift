import Testing
@testable import AwesoMuxCore

@Suite("BridgeSurfaceCommandPolicy")
struct BridgeSurfaceCommandPolicyTests {

    // MARK: - Remote-owned persistence

    private static func remoteOwnedPlan() -> PaneExecutionPlan {
        .ssh(
            SSHExecution(
                target: RemoteTarget(user: "ed", host: "box")!,
                persistenceOwner: .remoteZmx,
                sessionName: RemoteSessionName(rawValue: "dev")!
            )!)
    }

    @Test("a remote-owned pane attaches on the host regardless of bridge or amx availability")
    func remoteOwnedAttachWinsOverEveryOtherInput() {
        let plan = Self.remoteOwnedPlan()
        // The remote host owns the session: no local amx daemon is involved and
        // there is no bridge to wrap, so neither toggle can change the outcome
        // — and neither can make the pane unavailable.
        #expect(
            BridgeSurfaceCommandPolicy.command(
                bridgeEnabled: true, attachCommandAvailable: true, executionPlan: plan
            ) == .remoteOwnedAttach)
        #expect(
            BridgeSurfaceCommandPolicy.command(
                bridgeEnabled: false, attachCommandAvailable: true, executionPlan: plan
            ) == .remoteOwnedAttach)
        #expect(
            BridgeSurfaceCommandPolicy.command(
                bridgeEnabled: true, attachCommandAvailable: false, executionPlan: plan
            ) == .remoteOwnedAttach)
        #expect(
            BridgeSurfaceCommandPolicy.command(
                bridgeEnabled: false, attachCommandAvailable: false, executionPlan: plan
            ) == .remoteOwnedAttach)
    }

    @Test("local-amx ssh and local plans keep their pre-existing selections")
    func remoteOwnedCaseLeavesEveryOtherPlanUnchanged() {
        let localAmxPlan = PaneExecutionPlan.ssh(
            SSHExecution(
                target: RemoteTarget(user: "ed", host: "box")!
            ))
        for available in [true, false] {
            for enabled in [true, false] {
                let sshCommand = BridgeSurfaceCommandPolicy.command(
                    bridgeEnabled: enabled,
                    attachCommandAvailable: available,
                    executionPlan: localAmxPlan
                )
                #expect(sshCommand == (enabled && available ? .bridgeAttach : .remoteUnavailable))
                // No ssh plan of any persistence owner may ever spawn a local
                // shell wearing the remote host's face (ADR-0022).
                #expect(sshCommand != .localShell)
                #expect(
                    BridgeSurfaceCommandPolicy.command(
                        bridgeEnabled: enabled,
                        attachCommandAvailable: available,
                        executionPlan: Self.remoteOwnedPlan()
                    ) != .localShell)

                #expect(
                    BridgeSurfaceCommandPolicy.command(
                        bridgeEnabled: enabled,
                        attachCommandAvailable: available,
                        executionPlan: .local
                    ) == (enabled && available ? .bridgeAttach : .localShell))
            }
        }
    }
}
