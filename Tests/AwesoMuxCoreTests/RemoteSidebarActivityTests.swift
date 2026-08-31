import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Remote sidebar activity")
struct RemoteSidebarActivityTests {
    @Test("fresh remote shell states drive the same chrome projection")
    func freshStatesDriveChrome() throws {
        let now = Date()
        for (liveness, expected) in [
            (RemoteForegroundLiveness.idleShell, AgentState.idle),
            (.busyShell, .running),
            (.liveCommand, .running),
        ] {
            let pane = try remotePane(liveness: liveness, sampledAt: now)
            #expect(pane.effectiveChromeState == expected)
        }
    }

    @Test("indeterminate and missing evidence fall back to OSC activity")
    func unavailableEvidenceFallsBack() throws {
        for state in [RemoteForegroundLiveness.indeterminate, .sessionNotFound] {
            var pane = try remotePane(liveness: state, sampledAt: Date())
            pane.shellActivity = .busy
            #expect(pane.effectiveChromeState == .running)
            pane.shellActivity = .idle
            #expect(pane.effectiveChromeState == .idle)
        }
    }

    @Test("stale evidence falls back and disconnect does not claim remote busy")
    func staleAndDisconnectedEvidenceFallsBack() throws {
        var stale = try remotePane(
            liveness: .busyShell,
            sampledAt: Date().addingTimeInterval(-(TerminalPane.remoteLivenessFreshnessThreshold + 1))
        )
        stale.shellActivity = .idle
        #expect(stale.effectiveChromeState == .idle)

        var disconnected = try remotePane(liveness: .busyShell, sampledAt: Date())
        disconnected.remoteConnectionHealth = .possiblyStale
        disconnected.shellActivity = .idle
        #expect(disconnected.effectiveChromeState == .idle)
    }

    @Test("fresh evidence from an old connection generation falls back")
    func oldGenerationEvidenceFallsBack() throws {
        var pane = try remotePane(liveness: .idleShell, sampledAt: Date())
        pane.remoteConnectionGeneration = "generation-2"
        pane.shellActivity = .busy

        #expect(pane.freshRemoteForegroundLiveness() == nil)
        #expect(pane.effectiveChromeState == .running)
    }

    @Test("local shell activity remains unchanged")
    func localShellIsUnchanged() {
        var pane = TerminalPane(
            title: "local",
            workingDirectory: "/tmp",
            shellActivity: .busy,
            executionPlan: .local
        )
        #expect(pane.effectiveChromeState == .running)
        pane.shellActivity = .idle
        #expect(pane.effectiveChromeState == .idle)
    }

    @Test("visual and VoiceOver state share the remote projection")
    func visualAndAccessibilityAgree() throws {
        let pane = try remotePane(liveness: .liveCommand, sampledAt: Date())
        let session = TerminalSession(
            title: "Remote shell",
            workingDirectory: "/tmp",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        #expect(session.effectiveChromeState == .running)
        let spoken = SidebarVisibleRows.workspaceAccessibilityLabel(
            title: session.title,
            agentKind: .shell,
            state: session.effectiveChromeState,
            bundle: .main,
            locale: Locale(identifier: "en")
        )
        #expect(spoken.contains("Running"))
    }

    private func remotePane(
        liveness: RemoteForegroundLiveness,
        sampledAt: Date
    ) throws -> TerminalPane {
        let target = try #require(RemoteTarget(parsing: "me@example.com"))
        var pane = TerminalPane(
            title: "remote",
            workingDirectory: "/tmp",
            shellActivity: liveness == .idleShell ? .busy : .idle,
            executionPlan: .ssh(SSHExecution(target: target))
        )
        pane.remoteForegroundLivenessSnapshot = RemoteForegroundLivenessSnapshot(
            workspaceID: UUID(),
            paneID: pane.id,
            terminalSessionID: pane.terminalSessionID,
            connectionGeneration: "generation",
            liveness: liveness,
            sampledAt: sampledAt
        )
        pane.remoteConnectionGeneration = "generation"
        return pane
    }
}
