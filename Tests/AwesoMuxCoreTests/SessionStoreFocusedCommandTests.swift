import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("SessionStore focused commands")
struct SessionStoreFocusedCommandTests {

    @Test("authoritative Codex detection reclaims a stale Grok tile identity")
    func authoritativeCodexDetectionReclaimsStaleGrokTileIdentity() {
        let session = TerminalSession(
            title: "awesomux",
            workingDirectory: "~",
            agentKind: .grok,
            agentState: .done
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [session])
        ])
        let reducer = VisibleTextAgentStateReducer()

        let decision = reducer.visibleTextDecision(
            detectedState: .waiting,
            detectedAgentKind: .codex,
            detectedKindIsAuthoritative: true,
            liveAgentKind: .grok,
            liveExecutionState: .done,
            liveDisplayState: .done,
            terminalIsActiveForAttention: true
        )
        #expect(decision.shouldApply)
        #expect(!decision.shouldApplyState)
        #expect(decision.agentKind == .codex)

        store.applyDetectedAgentState(
            id: session.id,
            detectedState: decision.shouldApplyState ? .waiting : nil,
            agentKind: decision.agentKind,
            clearsAttention: decision.clearsAttention
        )

        #expect(store.selectedSession?.activeAgentKind == .codex)
        #expect(store.selectedSession?.agentRollup().winningAgentKind == .codex)
        #expect(store.selectedSession?.agentState == .done)
    }

    private func makeStore(_ session: TerminalSession) -> SessionStore {
        SessionStore(groups: [
            SessionGroup(name: "main", sessions: [session])
        ])
    }

    @Test("marking a detected Codex question seen does not answer it")
    func detectedQuestionStaysPendingUntilAnswered() {
        let session = TerminalSession(title: "codex", workingDirectory: "~", agentKind: .codex, agentExecutionState: .thinking)
        let store = makeStore(session)
        #expect(
            store.applyDetectedAgentState(
                id: session.id, detectedState: .needsAttention, isLiveCodexQuestion: true,
                clearsAttention: false, unreadNotificationDelta: 1))
        store.markPaneSeen(sessionID: session.id, paneID: session.activePaneID)
        #expect(store.selectedSession?.attentionReason == .userInputRequired)
        #expect(store.selectedSession?.unreadNotificationCount == 0)
        _ = store.applyDetectedAgentState(id: session.id, detectedState: .thinking, clearsAttention: true)
        #expect(store.selectedSession?.attentionReason == .userInputRequired)
        #expect(store.resolveObservedCodexQuestion(id: session.id, paneID: session.activePaneID))
        #expect(store.selectedSession?.attentionReason == nil)
        #expect(store.selectedSession?.agentExecutionState == .thinking)
        _ = store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .codex, attentionReason: .permissionPrompt, phase: .notification),
            to: session.id, paneID: session.activePaneID, terminalIsFocused: true)
        #expect(store.selectedSession?.attentionReason == .permissionPrompt)
        #expect(!store.resolveObservedCodexQuestion(id: session.id, paneID: session.activePaneID))
        #expect(store.selectedSession?.attentionReason == .permissionPrompt)
        store.markNeedsAttentionPromptAnswered(id: session.id)
        _ = store.applyDetectedAgentState(id: session.id, detectedState: .waiting, clearsAttention: true)
        #expect(store.selectedSession?.agentState == .waiting)

        let background = TerminalSession(
            title: "background", workingDirectory: "~", agentKind: .codex,
            agentExecutionState: .waiting, attentionReason: .userInputRequired, unreadNotificationCount: 2)
        let backgroundStore = makeStore(background)
        #expect(backgroundStore.resolveObservedCodexQuestion(id: background.id, paneID: background.activePaneID))
        #expect(backgroundStore.selectedSession?.unreadNotificationCount == 2)
        #expect(backgroundStore.selectedSession?.agentExecutionState == .waiting)
    }

    enum Resolution: Sendable { case input, visibleWork, beforeHook, waitingInput }

    @Test(
        "resolved prompts clear while later permission requests remain visible",
        arguments: [
            Resolution.input, .visibleWork, .beforeHook, .waitingInput,
        ])
    func promptLifecycle(resolution: Resolution) {
        let session = TerminalSession(
            title: "codex", workingDirectory: "~", agentKind: .codex,
            agentExecutionState: resolution == .waitingInput ? .waiting : (resolution == .beforeHook ? .thinking : .idle),
            attentionReason: resolution == .input || resolution == .visibleWork ? .permissionPrompt : nil,
            unreadNotificationCount: resolution == .input || resolution == .visibleWork ? 1 : 0)
        let store = makeStore(session)
        if resolution == .visibleWork {
            #expect(
                store.applyDetectedAgentState(
                    id: session.id, detectedState: .thinking, clearsAttention: true, clearsUnreadNotifications: true))
        } else {
            store.markNeedsAttentionPromptAnswered(id: session.id)
        }
        #expect(store.selectedSession?.attentionReason == nil)
        #expect(store.selectedSession?.needsUserInput == false)
        #expect(store.selectedSession?.agentState == (resolution == .waitingInput ? .waiting : .thinking))
        #expect(store.selectedSession?.unreadNotificationCount == 0)
        if resolution == .waitingInput || resolution == .beforeHook {
            #expect(
                store.applyAgentRuntimeEvent(
                    AgentRuntimeEvent(
                        source: .codex, attentionReason: .permissionPrompt, phase: .notification,
                        eventID: resolution == .waitingInput ? "real-permission" : "late-permission"),
                    to: session.id, paneID: session.activePaneID, terminalIsFocused: resolution == .beforeHook
                ))
            let pending = resolution == .waitingInput
            #expect(store.session(id: session.id)?.attentionReason == (pending ? .permissionPrompt : nil))
            #expect(store.session(id: session.id)?.needsUserInput == pending)
        }
    }
}
