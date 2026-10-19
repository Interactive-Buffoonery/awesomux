import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Remote foreground close risk")
struct RemoteForegroundCloseRiskTests {
    @Test(arguments: [
        (RemoteForegroundLiveness.busyShell, false, false, true),
        (.liveCommand, false, false, true),
        (.indeterminate, false, false, true), (.sessionNotFound, false, false, true),
        (.idleShell, true, false, true), (.idleShell, false, true, true),
        (.idleShell, false, false, false),
    ])
    func remoteEvidenceRemainsConservative(liveness: RemoteForegroundLiveness, stale: Bool, agentActive: Bool, expectedRisk: Bool) throws {
        let now = Date()
        let sampleTime = stale ? now.addingTimeInterval(-(TerminalPane.remoteLivenessFreshnessThreshold + 1)) : now
        var pane = try remotePane(now: sampleTime, liveness: liveness)
        if liveness == .busyShell || liveness == .liveCommand {
            pane.foregroundProcessLiveness = .idleShell
            pane.terminalPromptObserved = true
            pane.needsTerminalQuitConfirmation = false
        }
        if liveness == .idleShell {
            pane.foregroundProcessLiveness = .liveCommand
            pane.terminalPromptObserved = true
            pane.needsTerminalQuitConfirmation = true
        }
        if agentActive {
            pane.agentKind = .claudeCode
            pane.agentExecutionState = .thinking
            pane.lastAgentStateChangeAt = now
        }
        #expect(pane.isCloseRisk(at: now) == expectedRisk)
    }

    private func remotePane(
        now: Date,
        liveness: RemoteForegroundLiveness
    ) throws -> TerminalPane {
        let target = try #require(RemoteTarget(parsing: "me@example.com"))
        var pane = TerminalPane(
            title: "remote",
            workingDirectory: "/tmp",
            foregroundProcessLiveness: .bridgedIndeterminate,
            executionPlan: .ssh(SSHExecution(target: target))
        )
        pane.remoteForegroundLivenessSnapshot = snapshot(for: pane, now: now, liveness: liveness)
        pane.remoteConnectionGeneration = "generation"
        return pane
    }

    private func snapshot(
        for pane: TerminalPane,
        now: Date,
        liveness: RemoteForegroundLiveness
    ) -> RemoteForegroundLivenessSnapshot {
        RemoteForegroundLivenessSnapshot(
            workspaceID: UUID(),
            paneID: pane.id,
            terminalSessionID: pane.terminalSessionID,
            connectionGeneration: "generation",
            liveness: liveness,
            sampledAt: now
        )
    }
}
