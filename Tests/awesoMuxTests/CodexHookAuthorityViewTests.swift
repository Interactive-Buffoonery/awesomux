import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

// The helper E2E does not exercise view/store integration. These cases cover
// stale hook authority hiding approval prompts when the probe is unavailable,
// and an idle composer clearing thinking while the shell is still busy.
@MainActor
@Suite("Codex hook authority at the view boundary", .serialized)
struct CodexHookAuthorityViewTests {
    @Test("an unreadable foreground sample keeps approval detection available")
    func unreadableForegroundKeepsApprovalDetection() throws {
        let fixture = makeFixture(shellActivity: .idle)
        fixture.view.terminalEventState.codexHooksDelivered = (
            PaneStoreWriteKey(sessionID: fixture.session.id, paneID: fixture.pane.id),
            AgentForegroundIncarnation(pid: 123, startedAt: 456)
        )

        #expect(fixture.view.documentNudgeForegroundGeneration() == nil)
        #expect(!fixture.view.liveAgentHooksDelivered(for: .codex))
        fixture.view.applyDetectedAgentState(.needsAttention)

        let updated = try #require(
            fixture.store.session(id: fixture.session.id)?.layout.pane(id: fixture.pane.id)
        )
        #expect(updated.agentState == .needsAttention)
    }

    @Test("hookless waiting clears thinking only with a quiet shell", arguments: [ShellActivity.idle, .busy])
    func hooklessWaitingRespectsShellActivity(shellActivity: ShellActivity) throws {
        let fixture = makeFixture(shellActivity: shellActivity)
        #expect(!fixture.view.liveAgentHooksDelivered(for: .codex))

        fixture.view.applyDetectedAgentState(.waiting)

        let updated = try #require(
            fixture.store.session(id: fixture.session.id)?.layout.pane(id: fixture.pane.id)
        )
        #expect(updated.agentState == (shellActivity == .busy ? .thinking : .waiting))
    }

    private func makeFixture(shellActivity: ShellActivity) -> Fixture {
        let pane = TerminalPane(
            title: "Codex", workingDirectory: "/tmp", agentKind: .codex,
            agentState: .thinking, shellActivity: shellActivity, executionPlan: .local
        )
        let session = TerminalSession(
            title: "Codex", workingDirectory: "/tmp", layout: .pane(pane), activePaneID: pane.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "main", sessions: [session])], selectedSessionID: session.id
        )
        let runtime = GhosttyRuntime(initialCommandBridgeEnabled: true)
        let view = runtime.surfaceView(
            sessionStore: store, session: session, pane: pane,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )
        return Fixture(pane: pane, session: session, store: store, runtime: runtime, view: view)
    }

    private struct Fixture {
        let pane: TerminalPane
        let session: TerminalSession
        let store: SessionStore
        let runtime: GhosttyRuntime
        let view: GhosttySurfaceNSView
    }
}
