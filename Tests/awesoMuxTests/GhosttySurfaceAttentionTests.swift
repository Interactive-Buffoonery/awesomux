import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("Ghostty surface attention decisions")
struct GhosttySurfaceAttentionTests {
    @Test("runtime session end survives remount and blocks text and process inference")
    @MainActor
    func runtimeSessionEndSurvivesRemount() throws {
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
        let firstView = runtime.surfaceView(
            sessionStore: store,
            session: session,
            pane: pane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )

        firstView.applyAgentRuntimeEvent(
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionEnd
            ))

        #expect(store.session(id: session.id)?.agentKind == .shell)
        #expect(store.session(id: session.id)?.agentExecutionState == .idle)

        let remountedView = runtime.surfaceView(
            sessionStore: store,
            session: try #require(store.session(id: session.id)),
            pane: try #require(store.session(id: session.id)?.layout.pane(id: pane.id)),
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )
        remountedView.applyDetectedAgentOutput(
            AgentOutputDetection(
                state: .thinking,
                agentKind: .claudeCode
            ))
        remountedView.applyDetectedAgentOutput(
            AgentOutputDetection(
                state: .waiting,
                agentKind: .claudeCode,
                agentKindIsAuthoritative: true
            ))

        #expect(store.session(id: session.id)?.agentKind == .shell)
        #expect(store.session(id: session.id)?.agentExecutionState == .idle)

        remountedView.applyAgentRuntimeEvent(
            AgentRuntimeEvent(
                source: .claudeCode,
                kind: .claudeCode,
                executionState: .idle,
                phase: .sessionStart
            ))

        #expect(store.session(id: session.id)?.agentKind == .claudeCode)
    }

    @Test("suppressed detector update still clears a stale error on an ended pane")
    @MainActor
    func suppressedDetectorUpdateStillClearsStaleError() throws {
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

        // A crash-shaped end: the lifecycle latches suppression while the
        // pane keeps the error execution state the end event carried.
        view.applyAgentRuntimeEvent(
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .error,
                phase: .sessionEnd
            ))
        #expect(store.session(id: session.id)?.agentKind == .shell)
        #expect(
            store.session(id: session.id)?.layout.pane(id: pane.id)?.agentExecutionState
                == .error)

        // Later visible text moves past the error. The heuristic state change
        // stays suppressed, but the stale-error cleanup must still run.
        view.applyDetectedAgentOutput(
            AgentOutputDetection(
                state: .thinking,
                agentKind: .claudeCode
            ))
        #expect(store.session(id: session.id)?.agentKind == .shell)
        #expect(
            store.session(id: session.id)?.layout.pane(id: pane.id)?.agentExecutionState
                == .idle)
    }

    @Test("hookless provider end retains later heuristic fallback")
    @MainActor
    func hooklessProviderEndRetainsFallback() {
        let session = TerminalSession(
            title: "grok",
            workingDirectory: "~",
            agentKind: .grok,
            agentState: .running
        )
        let store = SessionStore(groups: [SessionGroup(name: "awesoMux", sessions: [session])])

        #expect(
            store.applyAgentRuntimeEvent(
                AgentRuntimeEvent(source: .grok, executionState: .idle, phase: .sessionEnd),
                to: session.id,
                paneID: session.activePaneID,
                terminalIsFocused: false
            ))
        #expect(
            store.applyDetectedAgentState(
                id: session.id,
                paneID: session.activePaneID,
                detectedState: .thinking,
                agentKind: .grok,
                clearsAttention: false
            ))
        #expect(store.session(id: session.id)?.agentKind == .grok)
        #expect(store.session(id: session.id)?.agentExecutionState == .thinking)
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
            layout: .split(
                TerminalSplit(
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
        #expect(
            !GhosttySurfaceNSView.shouldMarkGenericOutputNeedsAttention(
                isKeyWindow: true,
                isSelectedWorkspace: true
            ))
    }

    @Test("generic output attention still marks background workspaces")
    func genericOutputAttentionStillMarksBackgroundWorkspaces() {
        #expect(
            GhosttySurfaceNSView.shouldMarkGenericOutputNeedsAttention(
                isKeyWindow: true,
                isSelectedWorkspace: false
            ))
        #expect(
            GhosttySurfaceNSView.shouldMarkGenericOutputNeedsAttention(
                isKeyWindow: false,
                isSelectedWorkspace: true
            ))
    }
}
