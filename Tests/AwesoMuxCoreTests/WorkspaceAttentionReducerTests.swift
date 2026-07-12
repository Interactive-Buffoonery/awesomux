import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("WorkspaceAttentionReducer")
struct WorkspaceAttentionReducerTests {
    @Test("renaming a generated workspace clears its synthetic title metadata")
    func renameClearsSyntheticTitleMetadata() {
        var session = TerminalSession(
            title: "shell 1",
            workingDirectory: "~",
            syntheticTitle: SyntheticSessionTitle(agentKind: .shell, index: 1),
            agentKind: .shell
        )

        _ = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: session.activePaneID,
            update: .init(title: "release"),
            now: Date()
        )

        #expect(session.title == "release")
        #expect(session.syntheticTitle == nil)
    }

    @Test("updatePane sanitizes titles, clamps unread, and clears attention explicitly")
    func updatePaneAppliesAttentionRules() throws {
        var session = TerminalSession(
            title: "old",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .needsAttention,
            unreadNotificationCount: 2
        )

        let change = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: session.activePaneID,
            update: .init(
                title: "\u{202E}",
                agentExecutionState: .running,
                clearsAttention: true,
                unreadNotificationDelta: -99
            ),
            now: Date(timeIntervalSince1970: 1)
        )

        #expect(session.title == "old")
        #expect(session.agentExecutionState == .running)
        #expect(session.attentionReason == nil)
        #expect(session.unreadNotificationCount == 0)
        #expect(change?.oldCount == 2)
        #expect(change?.newCount == 0)
    }

    @Test("every execution-state event refreshes the activity clock (quit-risk liveness)")
    func executionStateEventRefreshesActivityClock() throws {
        var session = TerminalSession(
            title: "web",
            workingDirectory: "~",
            agentKind: .claudeCode
        )
        let paneID = session.activePaneID

        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID,
            update: .init(agentExecutionState: .running),
            now: Date(timeIntervalSince1970: 100)
        )
        #expect(session.layout.pane(id: paneID)?.lastAgentStateChangeAt == Date(timeIntervalSince1970: 100))

        // A repeated identical state is an activity heartbeat: it MUST refresh
        // the clock so `isQuitRisk()` keeps treating the agent as live (a fix
        // that gated this on value-change silently broke the quit-risk warning).
        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID,
            update: .init(agentExecutionState: .running),
            now: Date(timeIntervalSince1970: 200)
        )
        #expect(session.layout.pane(id: paneID)?.lastAgentStateChangeAt == Date(timeIntervalSince1970: 200))
    }

    @Test("permission queue mirrors count and clears only its own reason")
    func permissionPromptAttentionLifecycle() {
        var session = TerminalSession(title: "remote", workingDirectory: "~")
        let paneID = session.activePaneID

        _ = WorkspaceAttentionReducer.updatePermissionPromptAttention(
            &session, paneID: paneID, countDelta: 2, hasPending: true
        )
        #expect(session.layout.pane(id: paneID)?.attentionReason == .permissionPrompt)
        #expect(session.layout.pane(id: paneID)?.unreadNotificationCount == 2)

        _ = WorkspaceAttentionReducer.updatePermissionPromptAttention(
            &session, paneID: paneID, countDelta: -2, hasPending: false
        )
        #expect(session.layout.pane(id: paneID)?.attentionReason == nil)
        #expect(session.layout.pane(id: paneID)?.unreadNotificationCount == 0)
    }

    @Test("a lower-priority attentionReason cannot clobber a higher-priority pending one")
    func updatePaneDoesNotDowngradeHigherPriorityAttention() throws {
        var session = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            agentKind: .shell,
            attentionReason: .permissionPrompt
        )

        // A `.bell` arriving while a permission prompt is still pending must
        // not overwrite it (INT-506).
        _ = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: session.activePaneID,
            update: .init(attentionReason: .bell),
            now: Date(timeIntervalSince1970: 1)
        )
        #expect(session.attentionReason == .permissionPrompt)

        // A higher-priority reason still wins over an existing lower one.
        _ = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: session.activePaneID,
            update: .init(attentionReason: .userInputRequired),
            now: Date(timeIntervalSince1970: 2)
        )
        #expect(session.attentionReason == .userInputRequired)

        // Explicit clearing always wins regardless of priority.
        _ = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: session.activePaneID,
            update: .init(clearsAttention: true),
            now: Date(timeIntervalSince1970: 3)
        )
        #expect(session.attentionReason == nil)
    }

    @Test("one pane's waiting clears only its own attention; a sibling stays loud")
    func updatePaneIsScopedToOnePane() throws {
        // The regression PR #149 faked with the `isSinglePane` gate: in a split,
        // clearing one pane's attention must NOT touch the sibling's.
        let needy = TerminalPane(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            attentionReason: .permissionPrompt
        )
        let sibling = TerminalPane(
            title: "claude",
            workingDirectory: "~",
            agentKind: .claudeCode,
            attentionReason: .userInputRequired
        )
        var session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(needy),
                second: .pane(sibling)
            )),
            activePaneID: needy.id
        )

        _ = WorkspaceAttentionReducer.updatePane(
            &session,
            paneID: needy.id,
            update: .init(agentExecutionState: .waiting, clearsAttention: true),
            now: Date()
        )

        #expect(session.layout.pane(id: needy.id)?.attentionReason == nil)
        #expect(session.layout.pane(id: sibling.id)?.attentionReason == .userInputRequired)
        #expect(session.needsAcknowledgement == true)
    }

    @Test("a pane process error bumps unread only on first unfocused transition")
    func paneErrorsBumpUnreadOnlyOnFirstTransition() throws {
        var session = TerminalSession(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .running
        )

        let first = WorkspaceAttentionReducer.recordPaneExitError(
            &session,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )
        let second = WorkspaceAttentionReducer.recordPaneExitError(
            &session,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )

        #expect(session.attentionReason == .processError)
        #expect(session.unreadNotificationCount == 1)
        #expect(first?.newCount == 1)
        #expect(second == nil)
    }

    @Test("recordPaneExitError lands the error on the named pane, not the active one")
    func paneErrorLandsOnNamedPane() throws {
        let active = TerminalPane(title: "active", workingDirectory: "~", agentKind: .shell)
        let dead = TerminalPane(title: "dead", workingDirectory: "~", agentKind: .codex)
        var session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(active),
                second: .pane(dead)
            )),
            activePaneID: active.id
        )

        _ = WorkspaceAttentionReducer.recordPaneExitError(
            &session,
            paneID: dead.id,
            terminalIsFocused: false
        )

        #expect(session.layout.pane(id: dead.id)?.attentionReason == .processError)
        #expect(session.layout.pane(id: active.id)?.attentionReason == nil)
    }

    @Test("recordPaneExitError does not overwrite an existing live prompt")
    func paneErrorPreservesExistingPrompt() {
        // Consistency: a pane already showing a permission prompt must keep
        // it — a late process-exit error must not silently replace the reason the
        // user still needs to act on.
        var session = TerminalSession(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            attentionReason: .permissionPrompt
        )

        let change = WorkspaceAttentionReducer.recordPaneExitError(
            &session,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )

        #expect(session.attentionReason == .permissionPrompt)
        // Already in needs-attention, so no new unread bump either.
        #expect(change == nil)
    }

    @Test("acknowledgePane clears unread and attention")
    func acknowledgePaneClearsBoth() {
        var session = TerminalSession(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .needsAttention,
            unreadNotificationCount: 3
        )

        let change = WorkspaceAttentionReducer.acknowledgePane(
            &session,
            paneID: session.activePaneID
        )
        #expect(session.unreadNotificationCount == 0)
        #expect(session.attentionReason == nil)
        #expect(change?.oldCount == 3)
        #expect(change?.newCount == 0)
    }

    @Test("acknowledgePane clears attention-only without unread change")
    func acknowledgePaneAttentionOnly() {
        var session = TerminalSession(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .needsAttention,
            unreadNotificationCount: 0
        )

        let change = WorkspaceAttentionReducer.acknowledgePane(
            &session,
            paneID: session.activePaneID
        )
        #expect(session.attentionReason == nil)
        #expect(change == nil)
    }

    @Test("acknowledgeAllSessions clears every pane in a split")
    func acknowledgeAllClearsEveryPane() {
        let a = TerminalPane(
            title: "a", workingDirectory: "~", agentKind: .codex,
            attentionReason: .permissionPrompt, unreadNotificationCount: 2
        )
        let b = TerminalPane(
            title: "b", workingDirectory: "~", agentKind: .claudeCode,
            attentionReason: .userInputRequired, unreadNotificationCount: 1
        )
        var groups = [SessionGroup(name: "main", sessions: [
            TerminalSession(
                title: "split",
                workingDirectory: "~",
                layout: .split(TerminalSplit(
                    orientation: .vertical,
                    first: .pane(a),
                    second: .pane(b)
                )),
                activePaneID: a.id
            )
        ])]

        WorkspaceAttentionReducer.acknowledgeAllSessions(in: &groups)

        let session = groups[0].sessions[0]
        #expect(session.unreadNotificationCount == 0)
        #expect(session.needsAcknowledgement == false)
    }

    @Test("acknowledgeAllPanes clears every pane in one session only")
    func acknowledgeAllPanesClearsEveryPaneInSession() {
        let a = TerminalPane(
            title: "a", workingDirectory: "~", agentKind: .codex,
            attentionReason: .permissionPrompt, unreadNotificationCount: 2
        )
        let b = TerminalPane(
            title: "b", workingDirectory: "~", agentKind: .claudeCode,
            attentionReason: .userInputRequired, unreadNotificationCount: 1
        )
        var session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(a),
                second: .pane(b)
            )),
            activePaneID: a.id
        )

        let change = WorkspaceAttentionReducer.acknowledgeAllPanes(in: &session)

        // ⌘⇧K clears the WHOLE workspace — every pane, not just the active one.
        #expect(session.layout.pane(id: a.id)?.attentionReason == nil)
        #expect(session.layout.pane(id: b.id)?.attentionReason == nil)
        #expect(session.unreadNotificationCount == 0)
        #expect(session.needsAcknowledgement == false)
        #expect(change?.oldCount == 3)
        #expect(change?.newCount == 0)
    }

    @Test("acknowledgeAllPanes returns nil when nothing to clear")
    func acknowledgeAllPanesNoop() {
        var session = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            agentKind: .shell
        )

        let change = WorkspaceAttentionReducer.acknowledgeAllPanes(in: &session)
        #expect(change == nil)
    }

    @Test("clearStaleErrorIfPresent transitions error to idle on the pane")
    func clearStaleErrorTransitionsToIdle() {
        var session = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            agentKind: .shell,
            agentExecutionState: .error
        )

        let result = WorkspaceAttentionReducer.clearStaleErrorIfPresent(
            &session,
            paneID: session.activePaneID,
            now: Date(timeIntervalSince1970: 42)
        )
        #expect(result == true)
        #expect(session.agentExecutionState == .idle)
        #expect(session.lastAgentStateChangeAt == Date(timeIntervalSince1970: 42))
    }

    @Test("clearStaleErrorIfPresent no-ops for non-error state")
    func clearStaleErrorNoopsForNonError() {
        var session = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            agentKind: .shell,
            agentExecutionState: .running
        )

        let result = WorkspaceAttentionReducer.clearStaleErrorIfPresent(
            &session,
            paneID: session.activePaneID,
            now: Date()
        )
        #expect(result == false)
        #expect(session.agentExecutionState == .running)
    }
}
