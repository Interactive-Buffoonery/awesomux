import AwesoMuxBridgeProtocol
import AwesoMuxCore
import Testing

@Suite("WorkspaceDockBounceTracker")
struct WorkspaceDockBounceTrackerTests {
    @Test
    func requestsBounceWhenWorkspaceEntersNeedsAttentionWhileInactiveAndEnabled() {
        let session = makeSession(title: "agent")
        var tracker = WorkspaceDockBounceTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        let attentionSession = makeSession(
            id: session.id,
            title: "agent",
            state: .needsAttention
        )
        let shouldBounce = tracker.shouldRequestDockBounce(
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [attentionSession])],
            isAppActive: false,
            allowsDockBounce: true
        )

        #expect(shouldBounce)
    }

    @Test
    func seededNeedsAttentionDoesNotBounceUntilWorkspaceReenters() {
        let attentionSession = makeSession(
            title: "agent",
            state: .needsAttention
        )
        var tracker = WorkspaceDockBounceTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [attentionSession])
        ])

        expectBounce(
            false,
            tracker: &tracker,
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [attentionSession])],
            isAppActive: false,
            allowsDockBounce: true
        )

        let clearedSession = makeSession(id: attentionSession.id, title: "agent")
        expectBounce(
            false,
            tracker: &tracker,
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [clearedSession])],
            isAppActive: false,
            allowsDockBounce: true
        )

        expectBounce(
            true,
            tracker: &tracker,
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [attentionSession])],
            isAppActive: false,
            allowsDockBounce: true
        )
    }

    @Test
    func doesNotBounceWhileAppActiveOrDeferTheSameAttentionToFocusLoss() {
        let session = makeSession(title: "agent")
        var tracker = WorkspaceDockBounceTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        let attentionSession = makeSession(
            id: session.id,
            title: "agent",
            state: .needsAttention
        )
        expectBounce(
            false,
            tracker: &tracker,
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [attentionSession])],
            isAppActive: true,
            allowsDockBounce: true
        )

        expectBounce(
            false,
            tracker: &tracker,
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [attentionSession])],
            isAppActive: false,
            allowsDockBounce: true
        )
    }

    @Test
    func doesNotRepeatUntilWorkspaceLeavesAndReentersNeedsAttention() {
        let session = makeSession(title: "agent")
        var tracker = WorkspaceDockBounceTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        let attentionSession = makeSession(
            id: session.id,
            title: "agent",
            state: .needsAttention
        )
        expectBounce(
            true,
            tracker: &tracker,
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [attentionSession])],
            isAppActive: false,
            allowsDockBounce: true
        )
        expectBounce(
            false,
            tracker: &tracker,
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [attentionSession])],
            isAppActive: false,
            allowsDockBounce: true
        )

        let clearedSession = makeSession(id: session.id, title: "agent")
        expectBounce(
            false,
            tracker: &tracker,
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [clearedSession])],
            isAppActive: false,
            allowsDockBounce: true
        )
        expectBounce(
            true,
            tracker: &tracker,
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [attentionSession])],
            isAppActive: false,
            allowsDockBounce: true
        )
    }

    @Test
    func secondPaneAttentionDoesNotBounceAlreadyNeedyWorkspace() {
        let first = TerminalPane(
            title: "claude",
            workingDirectory: "~",
            agentKind: .claudeCode,
            executionPlan: .local
        )
        let second = TerminalPane(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            executionPlan: .local
        )
        let initial = makeSplitSession(first: first, second: second)
        var tracker = WorkspaceDockBounceTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [initial])
        ])

        let firstAttention = makeSplitSession(
            id: initial.id,
            first: pane(first, attentionReason: .permissionPrompt),
            second: second
        )
        expectBounce(
            true,
            tracker: &tracker,
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [firstAttention])],
            isAppActive: false,
            allowsDockBounce: true
        )

        let bothAttention = makeSplitSession(
            id: initial.id,
            first: pane(first, attentionReason: .permissionPrompt),
            second: pane(second, attentionReason: .userInputRequired)
        )
        expectBounce(
            false,
            tracker: &tracker,
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [bothAttention])],
            isAppActive: false,
            allowsDockBounce: true
        )
    }

    @Test
    func workspaceMustLeaveAttentionBeforeSecondPaneCanBounceAgain() {
        let first = TerminalPane(
            title: "claude",
            workingDirectory: "~",
            agentKind: .claudeCode,
            executionPlan: .local
        )
        let second = TerminalPane(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            executionPlan: .local
        )
        let initial = makeSplitSession(first: first, second: second)
        var tracker = WorkspaceDockBounceTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [initial])
        ])

        let firstAttention = makeSplitSession(
            id: initial.id,
            first: pane(first, attentionReason: .permissionPrompt),
            second: second
        )
        expectBounce(
            true,
            tracker: &tracker,
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [firstAttention])],
            isAppActive: false,
            allowsDockBounce: true
        )

        let secondAttention = makeSplitSession(
            id: initial.id,
            first: first,
            second: pane(second, attentionReason: .userInputRequired)
        )
        expectBounce(
            false,
            tracker: &tracker,
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [secondAttention])],
            isAppActive: false,
            allowsDockBounce: true
        )

        let firstAgain = makeSplitSession(
            id: initial.id,
            first: pane(first, attentionReason: .permissionPrompt),
            second: pane(second, attentionReason: .userInputRequired)
        )
        expectBounce(
            false,
            tracker: &tracker,
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [firstAgain])],
            isAppActive: false,
            allowsDockBounce: true
        )
    }

    @Test
    func gatesOnPreferenceOutputAttentionAndWorkspaceMute() {
        let session = makeSession(title: "agent")
        let attentionSession = makeSession(
            id: session.id,
            title: "agent",
            state: .needsAttention
        )

        var preferenceTracker = WorkspaceDockBounceTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        expectBounce(
            false,
            tracker: &preferenceTracker,
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [attentionSession])],
            isAppActive: false,
            allowsDockBounce: false
        )

        var outputGateTracker = WorkspaceDockBounceTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
        expectBounce(
            false,
            tracker: &outputGateTracker,
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [attentionSession])],
            isAppActive: false,
            outputMarksNeedsAttention: false,
            allowsDockBounce: true
        )

        let mutedSession = makeSession(title: "agent", notificationsMuted: true)
        let mutedAttentionSession = makeSession(
            id: mutedSession.id,
            title: "agent",
            state: .needsAttention,
            notificationsMuted: true
        )
        var muteTracker = WorkspaceDockBounceTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [mutedSession])
        ])
        expectBounce(
            false,
            tracker: &muteTracker,
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [mutedAttentionSession])],
            isAppActive: false,
            allowsDockBounce: true
        )
    }

    @Test
    func waitingTurnDoneDoesNotBounce() {
        let session = makeSession(title: "agent")
        var tracker = WorkspaceDockBounceTracker(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])

        let waitingSession = makeSession(
            id: session.id,
            title: "agent",
            agentExecutionState: .waiting
        )
        expectBounce(
            false,
            tracker: &tracker,
            afterUpdating: [SessionGroup(name: "awesoMux", sessions: [waitingSession])],
            isAppActive: false,
            allowsDockBounce: true
        )
    }

    private func expectBounce(
        _ expected: Bool,
        tracker: inout WorkspaceDockBounceTracker,
        afterUpdating groups: [SessionGroup],
        isAppActive: Bool,
        outputMarksNeedsAttention: Bool = true,
        allowsDockBounce: Bool
    ) {
        let actual = tracker.shouldRequestDockBounce(
            afterUpdating: groups,
            isAppActive: isAppActive,
            outputMarksNeedsAttention: outputMarksNeedsAttention,
            allowsDockBounce: allowsDockBounce
        )
        #expect(actual == expected)
    }

    private func makeSession(
        id: TerminalSession.ID = TerminalSession.ID(),
        title: String,
        state: AgentState? = nil,
        agentExecutionState: AgentExecutionState? = nil,
        notificationsMuted: Bool = false
    ) -> TerminalSession {
        TerminalSession(
            id: id,
            title: title,
            workingDirectory: "~",
            notificationsMuted: notificationsMuted,
            agentKind: .claudeCode,
            agentState: state,
            agentExecutionState: agentExecutionState
        )
    }

    private func makeSplitSession(
        id: TerminalSession.ID = TerminalSession.ID(),
        first: TerminalPane,
        second: TerminalPane
    ) -> TerminalSession {
        TerminalSession(
            id: id,
            title: "split",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(first),
                second: .pane(second)
            )),
            activePaneID: first.id
        )
    }

    private func pane(
        _ source: TerminalPane,
        attentionReason: AttentionReason
    ) -> TerminalPane {
        TerminalPane(
            id: source.id,
            title: source.title,
            workingDirectory: source.workingDirectory,
            agentKind: source.agentKind,
            attentionReason: attentionReason,
            executionPlan: .local
        )
    }
}
