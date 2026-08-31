import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Remote foreground close risk")
struct RemoteForegroundCloseRiskTests {
    @Test("fresh remote idle replaces local ssh and OSC busy evidence")
    func freshIdleWins() throws {
        let now = Date()
        var pane = try remotePane(now: now, liveness: .idleShell)
        pane.foregroundProcessLiveness = .liveCommand
        pane.terminalPromptObserved = true
        pane.needsTerminalQuitConfirmation = true

        #expect(!pane.isCloseRisk(at: now))
        #expect(pane.terminalPromptObserved)
    }

    @Test("fresh remote busy and command evidence are risky")
    func freshRemoteWorkIsRisky() throws {
        let now = Date()
        for state in [RemoteForegroundLiveness.busyShell, .liveCommand] {
            var pane = try remotePane(now: now, liveness: state)
            pane.foregroundProcessLiveness = .idleShell
            pane.terminalPromptObserved = true
            pane.needsTerminalQuitConfirmation = false
            #expect(pane.isCloseRisk(at: now))
        }
    }

    @Test("indeterminate, missing, and stale samples fail closed")
    func unavailableEvidenceIsConservative() throws {
        let now = Date()
        for state in [RemoteForegroundLiveness.indeterminate, .sessionNotFound] {
            let pane = try remotePane(now: now, liveness: state)
            #expect(pane.isCloseRisk(at: now))
        }
        let stale = try remotePane(
            now: now.addingTimeInterval(-(TerminalPane.remoteLivenessFreshnessThreshold + 1)),
            liveness: .idleShell
        )
        #expect(stale.isCloseRisk(at: now))
    }

    @Test("fresh agent activity remains risky over remote idle")
    func agentActivityRemainsAdditive() throws {
        let now = Date()
        var pane = try remotePane(now: now, liveness: .idleShell)
        pane.agentKind = .claudeCode
        pane.agentExecutionState = .thinking
        pane.lastAgentStateChangeAt = now
        #expect(pane.isCloseRisk(at: now))
    }

    @Test("remote zmx and local panes retain existing decisions")
    func otherExecutionPlansAreUnchanged() throws {
        let now = Date()
        let target = try #require(RemoteTarget(parsing: "me@example.com"))
        let name = try #require(RemoteSessionName(rawValue: "owned"))
        var pane = TerminalPane(
            title: "remote zmx",
            workingDirectory: "/tmp",
            foregroundProcessLiveness: .liveCommand,
            executionPlan: .ssh(SSHExecution(target: target, remoteSessionName: name))
        )
        pane.remoteForegroundLivenessSnapshot = snapshot(for: pane, now: now, liveness: .idleShell)
        #expect(pane.isCloseRisk(at: now))
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
