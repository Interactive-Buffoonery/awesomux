import Testing
import Foundation
@testable import AwesoMuxCore

@Suite("INT-504 close / recycle / independence")
@MainActor
struct PerPaneCloseRecycleTests {
    private func splitStore(
        first: TerminalPane,
        second: TerminalPane,
        active: TerminalPane.ID? = nil
    ) -> (store: SessionStore, sessionID: TerminalSession.ID) {
        let session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(first),
                second: .pane(second)
            )),
            activePaneID: active ?? first.id
        )
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])
        return (store, session.id)
    }

    @Test("two panes hold independent runtime states; the rollup picks the loudest")
    func independentPaneStatesRollUpToLoudest() {
        let a = TerminalPane(title: "a", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        let b = TerminalPane(title: "b", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        let (store, sessionID) = splitStore(first: a, second: b)

        // Pane A goes thinking (Codex); pane B needs attention (Claude).
        _ = store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .codex, state: .thinking),
            to: sessionID, paneID: a.id, terminalIsFocused: true
        )
        _ = store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, attentionReason: .permissionPrompt),
            to: sessionID, paneID: b.id, terminalIsFocused: true
        )

        let session = store.session(id: sessionID)
        #expect(session?.layout.pane(id: a.id)?.agentExecutionState == .thinking)
        #expect(session?.layout.pane(id: a.id)?.agentKind == .codex)
        #expect(session?.layout.pane(id: b.id)?.attentionReason == .permissionPrompt)
        #expect(session?.layout.pane(id: b.id)?.agentKind == .claudeCode)
        // Loudest wins: needsAttention (B) over thinking (A).
        let rollup = session!.agentRollup()
        #expect(rollup.state == .needsAttention)
        #expect(rollup.winningPaneID == b.id)
        #expect(rollup.winningAgentKind == .claudeCode)
    }

    @Test("selection ack clears the active pane only; a sibling stays loud")
    func acknowledgeClearsActivePaneOnly() {
        let active = TerminalPane(
            title: "active", workingDirectory: "~", agentKind: .codex,
            attentionReason: .permissionPrompt, unreadNotificationCount: 1,
            executionPlan: .local
        )
        let sibling = TerminalPane(
            title: "sibling", workingDirectory: "~", agentKind: .claudeCode,
            attentionReason: .userInputRequired, unreadNotificationCount: 2,
            executionPlan: .local
        )
        let (store, sessionID) = splitStore(first: active, second: sibling, active: active.id)

        store.acknowledgeSession(id: sessionID)

        let session = store.session(id: sessionID)
        #expect(session?.layout.pane(id: active.id)?.attentionReason == nil)
        #expect(session?.layout.pane(id: active.id)?.unreadNotificationCount == 0)
        // The sibling still needs you — the workspace row stays loud.
        #expect(session?.layout.pane(id: sibling.id)?.attentionReason == .userInputRequired)
        #expect(session?.needsAcknowledgement == true)
        #expect(store.unreadNotificationTotal == 2)
    }

    @Test("acknowledge-all clears every pane in the workspace")
    func acknowledgeAllClearsEveryPane() {
        let active = TerminalPane(
            title: "active", workingDirectory: "~", agentKind: .codex,
            attentionReason: .permissionPrompt, unreadNotificationCount: 1,
            executionPlan: .local
        )
        let sibling = TerminalPane(
            title: "sibling", workingDirectory: "~", agentKind: .claudeCode,
            attentionReason: .userInputRequired, unreadNotificationCount: 2,
            executionPlan: .local
        )
        let (store, sessionID) = splitStore(first: active, second: sibling, active: active.id)

        store.acknowledgeAllSessions()

        let session = store.session(id: sessionID)
        #expect(session?.needsAcknowledgement == false)
        #expect(session?.unreadNotificationCount == 0)
        #expect(store.unreadNotificationTotal == 0)
    }

    @Test("closing a pane carrying attention + unread settles the rollup and total")
    func closingPaneSettlesAggregates() {
        let keep = TerminalPane(title: "keep", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        let doomed = TerminalPane(
            title: "doomed", workingDirectory: "~", agentKind: .codex,
            attentionReason: .permissionPrompt, unreadNotificationCount: 2,
            executionPlan: .local
        )
        let (store, sessionID) = splitStore(first: keep, second: doomed, active: keep.id)
        #expect(store.unreadNotificationTotal == 2)

        _ = store.closePane(id: doomed.id, in: sessionID)

        let session = store.session(id: sessionID)
        #expect(session?.layout.pane(id: doomed.id) == nil)
        #expect(session?.needsAcknowledgement == false)
        #expect(session?.unreadNotificationCount == 0)
        #expect(store.unreadNotificationTotal == 0)
        #expect(store.sessionsAtRiskOnQuit.isEmpty)
    }

    @Test("reopening a closed split preserves each pane's agent kind")
    func reopenPreservesSiblingPaneKinds() {
        let shell = TerminalPane(title: "shell", workingDirectory: "~/work", agentKind: .shell, executionPlan: .local)
        let codex = TerminalPane(title: "codex", workingDirectory: "~/work", agentKind: .codex, executionPlan: .local)
        let session = TerminalSession(
            title: "split",
            workingDirectory: "~/work",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(shell),
                second: .pane(codex)
            )),
            activePaneID: shell.id
        )
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])

        store.closeSession(id: session.id)
        let reopenedID = store.reopenMostRecentlyClosed()

        let reopened = reopenedID.flatMap { store.session(id: $0) }
        let kinds = Set((reopened?.panes ?? []).map(\.agentKind))
        // The Codex sibling must not downgrade to a bare shell on reopen.
        #expect(kinds == [.shell, .codex])
        // Reopened panes come back idle and clean.
        #expect(reopened?.panes.allSatisfy { $0.agentExecutionState == .idle } == true)
        #expect(reopened?.unreadNotificationCount == 0)
    }

    @Test("recycling the active pane wipes its attention, unread, and quit-confirm risk")
    func recyclingActivePaneResetsState() {
        var dirty = TerminalPane(
            title: "dirty", workingDirectory: "~", agentKind: .codex,
            agentExecutionState: .thinking,
            attentionReason: .permissionPrompt,
            unreadNotificationCount: 4,
            executionPlan: .local
        )
        dirty.shellActivity = .busy
        dirty.needsTerminalQuitConfirmation = true
        let session = TerminalSession(
            title: "solo",
            workingDirectory: "~",
            layout: .pane(dirty),
            activePaneID: dirty.id
        )
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])
        #expect(store.unreadNotificationTotal == 4)

        _ = store.recycleActivePane(in: session.id)

        let recycled = store.session(id: session.id)?.activePane
        #expect(recycled?.agentKind == .shell)
        #expect(recycled?.agentExecutionState == .idle)
        #expect(recycled?.attentionReason == nil)
        #expect(recycled?.unreadNotificationCount == 0)
        #expect(recycled?.needsTerminalQuitConfirmation == false)
        #expect(recycled?.shellActivity == .idle)
        #expect(store.unreadNotificationTotal == 0)
        #expect(store.sessionsAtRiskOnQuit.isEmpty)
    }
}
