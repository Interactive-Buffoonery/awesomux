import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("SessionStore bridge process errors")
struct SessionStoreBridgeProcessErrorTests {
    @Test("records bridge loss as a pane error, not generic attention")
    func recordsBridgeLossAsPaneError() {
        let session = TerminalSession(
            title: "bridge",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = makeStore(session)

        let recorded = store.recordPaneProcessError(
            in: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )

        let pane = store.selectedSession?.layout.pane(id: session.activePaneID)
        #expect(recorded)
        #expect(pane?.agentExecutionState == .error)
        #expect(pane?.attentionReason == nil)
        #expect(store.selectedSession?.agentState == .error)
        #expect(store.selectedSession?.unreadNotificationCount == 1)
        #expect(store.unreadNotificationTotal == 1)
    }

    @Test("focused bridge loss does not bump unread")
    func focusedBridgeLossDoesNotBumpUnread() {
        let session = TerminalSession(
            title: "bridge",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running
        )
        let store = makeStore(session)

        let recorded = store.recordPaneProcessError(
            in: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: true
        )

        #expect(recorded)
        #expect(store.selectedSession?.agentState == .error)
        #expect(store.selectedSession?.unreadNotificationCount == 0)
        #expect(store.unreadNotificationTotal == 0)
    }

    /// A dead process cannot answer the prompt it raised, so the error record has
    /// to retract it. Without an authoritative clear the reason survives the
    /// `awaitsExplicitAnswer` guard, the pane resolves to `.needsAttention`
    /// instead of `.error`, and the workspace paints peach — holding a Needs
    /// Input slot for a prompt nobody can answer and hiding the recovery hint.
    @Test("bridge loss retracts the prompt the dead process can no longer answer")
    func bridgeLossRetractsPendingPrompt() {
        var session = TerminalSession(
            title: "bridge",
            workingDirectory: "~",
            agentKind: .claudeCode,
            agentState: .running
        )
        session.layout = session.layout.mappingPanes { pane in
            var pane = pane
            pane.attentionReason = .permissionPrompt
            return pane
        }
        let store = makeStore(session)

        let recorded = store.recordPaneProcessError(
            in: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: true
        )

        let pane = store.selectedSession?.layout.pane(id: session.activePaneID)
        #expect(recorded)
        #expect(pane?.attentionReason == nil)
        #expect(pane?.agentExecutionState == .error)
        #expect(store.selectedSession?.agentState == .error)
        #expect(store.selectedSession?.needsUserInput == false)
    }

    private func makeStore(_ session: TerminalSession) -> SessionStore {
        SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
    }
}

@MainActor
@Suite("SessionStore sibling pane exit errors")
struct SessionStoreSiblingPaneExitErrorTests {
    @Test("increments unread count when terminal is unfocused")
    func incrementsUnreadCountWhenUnfocused() {
        let session = makeSession(state: .running, unreadNotificationCount: 2)
        let store = makeStore(session)

        let recorded = store.recordSiblingPaneExitError(
            in: session.id,
            exitingPaneID: session.activePaneID,
            terminalIsFocused: false
        )

        #expect(recorded)
        #expect(store.selectedSession?.unreadNotificationCount == 3)
        // Pins the latent fix: the app-wide total must follow the per-session
        // bump. The pre-extraction monolith updated the session count but left
        // `unreadNotificationTotal` stale until the next structural rebuild.
        #expect(store.unreadNotificationTotal == 3)
    }

    @Test("records the exit error on the exiting pane before it is removed")
    func recordsExitErrorOnExitingPaneBeforeRemoval() {
        // M2 (INT-504 review): pane B exits non-zero in a 2-pane split. The exit
        // handler now RECORDS the error on B while it is still in the layout,
        // BEFORE closePane removes it (record-before-removal, maintainer decision) — the
        // prior close-first ordering no-oped because the dead pane was already
        // gone. The badge lands on the correct (exiting) pane and never on the
        // innocent survivor A.
        let paneA = TerminalPane(title: "A", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        let paneB = TerminalPane(
            title: "B", workingDirectory: "~", agentKind: .codex, agentState: .running,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(paneA),
                    second: .pane(paneB)
                )),
            activePaneID: paneB.id
        )
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])

        // Record FIRST, while B is still present (mirrors the corrected
        // exit-handler ordering: record before the dead pane is removed).
        let recorded = store.recordSiblingPaneExitError(
            in: session.id,
            exitingPaneID: paneB.id,
            terminalIsFocused: false
        )

        #expect(recorded)
        #expect(
            store.session(id: session.id)?.layout.pane(id: paneB.id)?.attentionReason
                == .processError
        )
        // The survivor is never badged.
        #expect(store.session(id: session.id)?.layout.pane(id: paneA.id)?.attentionReason == nil)

        // Then closePane removes B and collapses the split onto A.
        _ = store.closePane(id: paneB.id, in: session.id)
        #expect(store.session(id: session.id)?.layout.pane(id: paneA.id)?.attentionReason == nil)
    }

    @Test("badges the exiting pane when it is still held in the layout")
    func badgesExitingPaneWhenStillPresent() {
        // Forward-compat with INT-506: when the exiting pane is still in the
        // layout (a held-dead pane), the error attaches to IT, never a sibling.
        let paneA = TerminalPane(title: "A", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        let paneB = TerminalPane(
            title: "B", workingDirectory: "~", agentKind: .codex, agentState: .running,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(paneA),
                    second: .pane(paneB)
                )),
            activePaneID: paneA.id
        )
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])

        let recorded = store.recordSiblingPaneExitError(
            in: session.id,
            exitingPaneID: paneB.id,
            terminalIsFocused: false
        )

        #expect(recorded)
        #expect(
            store.session(id: session.id)?.layout.pane(id: paneB.id)?.attentionReason == .processError
        )
        #expect(store.session(id: session.id)?.layout.pane(id: paneA.id)?.attentionReason == nil)
    }

    private func makeSession(
        state: AgentState,
        unreadNotificationCount: Int = 0
    ) -> TerminalSession {
        TerminalSession(
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: state,
            unreadNotificationCount: unreadNotificationCount
        )
    }

    private func makeStore(_ session: TerminalSession) -> SessionStore {
        SessionStore(groups: [
            SessionGroup(name: "awesoMux", sessions: [session])
        ])
    }
}
