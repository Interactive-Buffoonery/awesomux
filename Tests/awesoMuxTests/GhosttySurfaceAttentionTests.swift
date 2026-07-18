import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("Ghostty surface attention decisions")
struct GhosttySurfaceAttentionTests {
    @Test("runtime session end blocks text state until the next session starts")
    @MainActor
    func runtimeSessionEndBlocksTextStateUntilRestart() throws {
        let pane = TerminalPane(
            title: "claude",
            workingDirectory: "~",
            agentKind: .claudeCode,
            agentExecutionState: .thinking,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "agent",
            workingDirectory: "~",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        let runtime = GhosttyRuntime()
        let view = runtime.surfaceView(
            sessionStore: store,
            session: session,
            pane: pane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )

        view.applyAgentRuntimeEvent(
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionEnd
            ))

        #expect(view.runtimeSessionHasEnded)
        #expect(store.session(id: session.id)?.agentKind == .shell)
        #expect(store.session(id: session.id)?.agentExecutionState == .idle)

        view.applyAgentRuntimeEvent(
            AgentRuntimeEvent(
                source: .claudeCode,
                kind: .claudeCode,
                executionState: .idle,
                phase: .sessionStart
            ))

        #expect(!view.runtimeSessionHasEnded)
        #expect(store.session(id: session.id)?.agentKind == .claudeCode)
    }

    @Test("visible-text suppression reads this pane's state, not the loudest sibling")
    @MainActor
    func suppressionReadsOwnPaneState() {
        // M4: a sibling pane already in `.needsAttention` makes the session's
        // loudest-pane fold `.needsAttention`. Feeding THAT into visible-text
        // suppression would mask this pane detecting its OWN `.needsAttention`.
        // The suppression input must be this pane's own state.
        let thisPane = TerminalPane(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            agentExecutionState: .running,
            executionPlan: .local
        )
        let sibling = TerminalPane(
            title: "claude",
            workingDirectory: "~",
            agentKind: .claudeCode,
            attentionReason: .permissionPrompt,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(thisPane),
                second: .pane(sibling)
            )),
            activePaneID: thisPane.id
        )

        // The loudest-pane fold is the sibling's `.needsAttention`.
        #expect(session.agentState == .needsAttention)
        // The suppression input is THIS pane's own state instead.
        #expect(
            GhosttySurfaceNSView.visibleTextSuppressionLiveState(
                in: session,
                paneID: thisPane.id
            ) == .running
        )
    }

    @Test("selected key workspace suppresses generic output attention")
    func selectedKeyWorkspaceSuppressesGenericOutputAttention() {
        #expect(!GhosttySurfaceNSView.shouldMarkGenericOutputNeedsAttention(
            isKeyWindow: true,
            isSelectedWorkspace: true
        ))
    }

    @Test("generic output attention still marks background workspaces")
    func genericOutputAttentionStillMarksBackgroundWorkspaces() {
        #expect(GhosttySurfaceNSView.shouldMarkGenericOutputNeedsAttention(
            isKeyWindow: true,
            isSelectedWorkspace: false
        ))
        #expect(GhosttySurfaceNSView.shouldMarkGenericOutputNeedsAttention(
            isKeyWindow: false,
            isSelectedWorkspace: true
        ))
    }
}
