import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("SessionStore focused commands")
struct SessionStoreFocusedCommandTests {
    @Test("renameSession sanitizes title and marks it user-edited")
    func renameSessionSanitizesTitleAndMarksUserEdited() {
        let store = SessionStore(groups: SessionStore.previewGroups)
        let sessionID = SessionStore.previewGroups[0].sessions[0].id
        let longTitle = String(repeating: "a", count: SessionStore.maxTitleLength + 10)

        store.renameSession(
            id: sessionID,
            title: "  \(longTitle)\u{202E}\n  "
        )

        #expect(store.selectedSession?.title.count == SessionStore.maxTitleLength)
        #expect(store.selectedSession?.title.contains("\u{202E}") == false)
        #expect(store.selectedSession?.title.contains("\n") == false)
        #expect(store.selectedSession?.title.contains("\u{2028}") == false)
        #expect(store.selectedSession?.title.contains("\u{200B}") == false)
        #expect(store.selectedSession?.isTitleUserEdited == true)
    }

    @Test("markSessionNeedsAttention increments unread and sets attention state")
    func markSessionNeedsAttentionIncrementsUnreadAndSetsAttentionState() {
        let session = makeSession()
        let store = makeStore(session)

        store.markSessionNeedsAttention(id: session.id, unreadNotificationDelta: 1)

        #expect(store.selectedSession?.agentState == .needsAttention)
        #expect(store.selectedSession?.unreadNotificationCount == 1)
        #expect(store.unreadNotificationTotal == 1)
    }

    @Test("applyDetectedAgentState applies display state and clears attention")
    func applyDetectedAgentStateAppliesDisplayStateAndClearsAttention() {
        let session = TerminalSession(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .needsAttention,
            unreadNotificationCount: 2
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [session])
        ])

        store.applyDetectedAgentState(
            id: session.id,
            detectedState: .running,
            clearsAttention: true,
            unreadNotificationDelta: 1
        )

        #expect(store.selectedSession?.agentState == .running)
        #expect(store.selectedSession?.attentionReason == nil)
        #expect(store.selectedSession?.unreadNotificationCount == 3)
        #expect(store.unreadNotificationTotal == 3)
    }

    @Test("applyDetectedAgentState can acknowledge stale unread attention")
    func applyDetectedAgentStateCanAcknowledgeStaleUnreadAttention() {
        let session = TerminalSession(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .needsAttention,
            unreadNotificationCount: 2
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [session])
        ])

        store.applyDetectedAgentState(
            id: session.id,
            detectedState: .thinking,
            clearsAttention: true,
            clearsUnreadNotifications: true
        )

        #expect(store.selectedSession?.agentState == .thinking)
        #expect(store.selectedSession?.attentionReason == nil)
        #expect(store.selectedSession?.unreadNotificationCount == 0)
        #expect(store.unreadNotificationTotal == 0)
    }

    @Test("applyDetectedAgentState can correct stale visible-text identity")
    func applyDetectedAgentStateCanCorrectStaleVisibleTextIdentity() {
        let session = TerminalSession(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .thinking,
            unreadNotificationCount: 2
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [session])
        ])

        store.applyDetectedAgentState(
            id: session.id,
            detectedState: nil,
            agentKind: .claudeCode,
            clearsAttention: false
        )

        #expect(store.selectedSession?.agentKind == .claudeCode)
        #expect(store.selectedSession?.agentState == .thinking)
        #expect(store.selectedSession?.unreadNotificationCount == 2)
    }

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

    @Test("markNeedsAttentionPromptAnswered transitions to thinking and clears unread")
    func markNeedsAttentionPromptAnsweredTransitionsToThinkingAndClearsUnread() {
        let session = TerminalSession(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .needsAttention,
            unreadNotificationCount: 1
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [session])
        ])

        store.markNeedsAttentionPromptAnswered(id: session.id)

        #expect(store.selectedSession?.agentState == .thinking)
        #expect(store.selectedSession?.attentionReason == nil)
        #expect(store.selectedSession?.unreadNotificationCount == 0)
        #expect(store.unreadNotificationTotal == 0)
    }

    @Test("markNeedsAttentionPromptAnswered no-ops outside needs attention")
    func markNeedsAttentionPromptAnsweredNoopsOutsideNeedsAttention() {
        let session = TerminalSession(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .running,
            unreadNotificationCount: 2
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [session])
        ])

        store.markNeedsAttentionPromptAnswered(id: session.id)

        #expect(store.selectedSession?.agentState == .running)
        #expect(store.selectedSession?.attentionReason == nil)
        #expect(store.selectedSession?.unreadNotificationCount == 2)
        #expect(store.unreadNotificationTotal == 2)
    }

    private func makeSession(
        title: String = "codex",
        agentState: AgentState = .running,
        unreadNotificationCount: Int = 0
    ) -> TerminalSession {
        TerminalSession(
            title: title,
            workingDirectory: "~",
            agentKind: .codex,
            agentState: agentState,
            unreadNotificationCount: unreadNotificationCount
        )
    }

    private func makeStore(_ session: TerminalSession) -> SessionStore {
        SessionStore(groups: [
            SessionGroup(name: "main", sessions: [session])
        ])
    }
}
