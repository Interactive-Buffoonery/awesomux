import AwesoMuxCore
import Testing

@MainActor
@Suite("SessionStore public API")
struct SessionStorePublicAPITests {
    @Test("external modules can read groups and replace state from a snapshot")
    func externalModulesCanReadGroupsAndReplaceStateFromSnapshot() {
        let original = TerminalSession(
            title: "original",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let replacement = TerminalSession(
            title: "replacement",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "main", sessions: [original])],
            selectedSessionID: original.id
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "next", sessions: [replacement])],
            selectedSessionID: replacement.id
        )

        let summary = store.replaceState(restoring: snapshot)

        #expect(summary.isEmpty)
        #expect(store.groups.map(\.name) == ["next"])
        #expect(store.groups[0].sessions.map(\.id) == [replacement.id])
        #expect(store.selectedSessionID == replacement.id)
    }

    @Test("external modules can rename sessions")
    func externalModulesCanRenameSessions() {
        let (store, session) = makeStore()

        store.renameSession(id: session.id, title: "renamed")

        #expect(store.session(id: session.id)?.title == "renamed")
        #expect(store.session(id: session.id)?.isTitleUserEdited == true)
    }

    @Test("external modules can mark sessions as needing attention")
    func externalModulesCanMarkSessionsNeedsAttention() {
        let (store, session) = makeStore()

        store.markSessionNeedsAttention(id: session.id, unreadNotificationDelta: 2)

        #expect(store.session(id: session.id)?.agentState == .needsAttention)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 2)
        #expect(store.unreadNotificationTotal == 2)
    }

    @Test("external modules can apply detected agent state")
    func externalModulesCanApplyDetectedAgentState() {
        let (store, session) = makeStore(
            agentState: .needsAttention,
            unreadNotificationCount: 2
        )

        store.applyDetectedAgentState(
            id: session.id,
            detectedState: .running,
            clearsAttention: true,
            unreadNotificationDelta: 1
        )

        #expect(store.session(id: session.id)?.agentState == .running)
        #expect(store.session(id: session.id)?.attentionReason == nil)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 3)
        #expect(store.unreadNotificationTotal == 3)
    }

    @Test("external modules can mark needs-attention prompts answered")
    func externalModulesCanMarkNeedsAttentionPromptsAnswered() {
        let (store, session) = makeStore(
            agentState: .needsAttention,
            unreadNotificationCount: 4
        )

        store.markNeedsAttentionPromptAnswered(id: session.id)

        #expect(store.session(id: session.id)?.agentState == .thinking)
        #expect(store.session(id: session.id)?.attentionReason == nil)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 0)
        #expect(store.unreadNotificationTotal == 0)
    }

    #if DEBUG
    @Test("external modules can set debug agent state")
    func externalModulesCanSetDebugAgentState() {
        let (store, session) = makeStore(unreadNotificationCount: 1)

        store.setDebugAgentState(
            id: session.id,
            agentState: .waiting,
            clearsAttention: true,
            unreadNotificationDelta: 2
        )

        #expect(store.session(id: session.id)?.agentState == .waiting)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 3)
        #expect(store.unreadNotificationTotal == 3)
    }
    #endif

    @Test("public focused session commands do not decrement unread badges")
    func publicFocusedSessionCommandsDoNotDecrementUnreadBadges() {
        let (store, session) = makeStore(
            agentState: .running,
            unreadNotificationCount: 4
        )

        store.markSessionNeedsAttention(id: session.id, unreadNotificationDelta: -99)
        #expect(store.session(id: session.id)?.agentState == .needsAttention)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 4)
        #expect(store.unreadNotificationTotal == 4)

        store.applyDetectedAgentState(
            id: session.id,
            detectedState: .running,
            clearsAttention: true,
            unreadNotificationDelta: -99
        )
        #expect(store.session(id: session.id)?.agentState == .running)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 4)
        #expect(store.unreadNotificationTotal == 4)

        #if DEBUG
        store.setDebugAgentState(
            id: session.id,
            agentState: .waiting,
            unreadNotificationDelta: -99
        )
        #expect(store.session(id: session.id)?.agentState == .waiting)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 4)
        #expect(store.unreadNotificationTotal == 4)
        #endif
    }

    private func makeStore(
        title: String = "original",
        agentState: AgentState = .idle,
        unreadNotificationCount: Int = 0
    ) -> (SessionStore, TerminalSession) {
        let session = TerminalSession(
            title: title,
            workingDirectory: "~",
            agentKind: .codex,
            agentState: agentState,
            unreadNotificationCount: unreadNotificationCount
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "main", sessions: [session])],
            selectedSessionID: session.id
        )
        return (store, session)
    }
}
