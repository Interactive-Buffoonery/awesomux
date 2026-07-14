import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("WorkspaceAttentionAnnouncementTracker")
struct WorkspaceAttentionAnnouncementTrackerTests {
    @Test("spoken announcements resolve full sentences and plurals from an explicit locale")
    func spokenAnnouncementsResolveFromExplicitLocale() throws {
        let bundle = try #require(INT612LocalizationTestSupport.bundle)
        let first = WorkspaceAttentionAnnouncementTracker.Announcement(
            sessionID: UUID(),
            title: "revue",
            agentKind: .shell,
            state: .needsAttention
        )
        let second = WorkspaceAttentionAnnouncementTracker.Announcement(
            sessionID: UUID(),
            title: "tests",
            agentKind: .codex,
            state: .done
        )

        #expect(
            WorkspaceAttentionAnnouncementTracker.spokenAnnouncement(
                for: [first],
                bundle: bundle,
                locale: INT612LocalizationTestSupport.pseudoLocale
            ) == "⟦input:revue:⟦Shell⟧⟧")
        #expect(
            WorkspaceAttentionAnnouncementTracker.spokenAnnouncement(
                for: [first, second],
                bundle: bundle,
                locale: INT612LocalizationTestSupport.pseudoLocale
            ) == "⟦attention:2 workspaces⟧")
    }

    private func session(
        id: TerminalSession.ID = UUID(),
        title: String,
        kind: AgentKind,
        state: AgentState
    ) -> TerminalSession {
        TerminalSession(
            id: id,
            title: title,
            workingDirectory: "~",
            agentKind: kind,
            agentState: state
        )
    }

    @Test("announces a background workspace crossing into needs-attention")
    func announcesBackgroundCrossing() {
        let selected = session(title: "active", kind: .shell, state: .idle)
        let backgroundIdle = session(title: "agent", kind: .codex, state: .running)
        var tracker = WorkspaceAttentionAnnouncementTracker(groups: [
            SessionGroup(name: "main", sessions: [selected, backgroundIdle])
        ])

        let backgroundLoud = session(
            id: backgroundIdle.id, title: "agent", kind: .codex, state: .needsAttention
        )
        let announcements = tracker.announcements(
            afterUpdating: [SessionGroup(name: "main", sessions: [selected, backgroundLoud])],
            selectedSessionID: selected.id,
            isAppActive: true
        )

        #expect(announcements.count == 1)
        #expect(announcements.first?.sessionID == backgroundIdle.id)
        #expect(announcements.first?.agentKind == .codex)
        #expect(announcements.first?.state == .needsAttention)
        #expect(
            WorkspaceAttentionAnnouncementTracker.spokenAnnouncement(for: announcements)
                == "Codex in agent needs input."
        )
    }

    @Test("does not announce the focused workspace")
    func doesNotAnnounceFocusedWorkspace() {
        let focused = session(title: "active", kind: .codex, state: .running)
        var tracker = WorkspaceAttentionAnnouncementTracker(groups: [
            SessionGroup(name: "main", sessions: [focused])
        ])

        let focusedLoud = session(
            id: focused.id, title: "active", kind: .codex, state: .needsAttention
        )
        let announcements = tracker.announcements(
            afterUpdating: [SessionGroup(name: "main", sessions: [focusedLoud])],
            selectedSessionID: focused.id,
            isAppActive: true
        )

        #expect(announcements.isEmpty)
    }

    @Test("announces the selected workspace when the app is inactive")
    func announcesSelectedWorkspaceWhenAppInactive() {
        let selected = session(title: "active", kind: .codex, state: .running)
        var tracker = WorkspaceAttentionAnnouncementTracker(groups: [
            SessionGroup(name: "main", sessions: [selected])
        ])

        let loud = session(id: selected.id, title: "active", kind: .codex, state: .needsAttention)
        let announcements = tracker.announcements(
            afterUpdating: [SessionGroup(name: "main", sessions: [loud])],
            selectedSessionID: selected.id,
            isAppActive: false
        )

        #expect(announcements.count == 1)
    }

    @Test("does not re-announce a stable state across re-evaluations")
    func doesNotReAnnounceStableState() {
        let selected = session(title: "active", kind: .shell, state: .idle)
        let background = session(title: "agent", kind: .codex, state: .needsAttention)
        var tracker = WorkspaceAttentionAnnouncementTracker(groups: [
            SessionGroup(name: "main", sessions: [selected, background])
        ])

        // The background workspace was already loud at seed → no announcement on
        // a re-evaluation that doesn't change its state.
        let announcements = tracker.announcements(
            afterUpdating: [SessionGroup(name: "main", sessions: [selected, background])],
            selectedSessionID: selected.id,
            isAppActive: true
        )

        #expect(announcements.isEmpty)
    }

    @Test("announces a done/error crossing on an unfocused workspace")
    func announcesDoneAndError() {
        let selected = session(title: "active", kind: .shell, state: .idle)
        let working = session(title: "agent", kind: .codex, state: .running)
        var tracker = WorkspaceAttentionAnnouncementTracker(groups: [
            SessionGroup(name: "main", sessions: [selected, working])
        ])

        let done = session(id: working.id, title: "agent", kind: .codex, state: .done)
        let doneEvents = tracker.announcements(
            afterUpdating: [SessionGroup(name: "main", sessions: [selected, done])],
            selectedSessionID: selected.id,
            isAppActive: true
        )
        #expect(doneEvents.first?.state == .done)
        #expect(
            WorkspaceAttentionAnnouncementTracker.spokenAnnouncement(for: doneEvents)
                == "Codex in agent completed."
        )

        let error = session(id: working.id, title: "agent", kind: .codex, state: .error)
        let errorEvents = tracker.announcements(
            afterUpdating: [SessionGroup(name: "main", sessions: [selected, error])],
            selectedSessionID: selected.id,
            isAppActive: true
        )
        #expect(errorEvents.first?.state == .error)
    }

    @Test("reconcile collapses repeat transitions of one workspace to its latest")
    func reconcileDedupesBySession() {
        let sessionID = UUID()
        let first = WorkspaceAttentionAnnouncementTracker.Announcement(
            sessionID: sessionID, title: "ws", agentKind: .codex, state: .needsAttention
        )
        let second = WorkspaceAttentionAnnouncementTracker.Announcement(
            sessionID: sessionID, title: "ws", agentKind: .codex, state: .done
        )

        // Two transitions of the SAME workspace in one window must collapse to
        // one announcement (the live one), so the count never says "2 workspaces".
        let reconciled = WorkspaceAttentionAnnouncementTracker.reconcile(
            [first, second]
        ) { id in id == sessionID ? second : nil }

        #expect(reconciled.count == 1)
        #expect(reconciled.first?.state == .done)
        #expect(
            WorkspaceAttentionAnnouncementTracker.spokenAnnouncement(for: reconciled)
                == "Codex in ws completed."
        )
    }

    @Test(
        "spoken message uses AgentKind.spokenName, not rawValue, so a shell announcement stays consistent with the localized fallback title beside it"
    )
    func spokenMessageUsesSpokenNameForShell() {
        // PR-review finding: message(for:) previously read agentKind.rawValue directly,
        // which would speak "Shell" (unlocalized) right next to a workspace title that
        // can itself be a localized synthetic fallback ("shell 1") once a catalog
        // exists. spokenName routes .shell through the same localized text as
        // SessionStoreText's fallback prefix instead.
        let shellAnnouncement = WorkspaceAttentionAnnouncementTracker.Announcement(
            sessionID: UUID(), title: "shell 1", agentKind: .shell, state: .needsAttention
        )
        #expect(
            WorkspaceAttentionAnnouncementTracker.spokenAnnouncement(for: [shellAnnouncement])
                == "\(AgentKind.shell.spokenName) in shell 1 needs input."
        )
    }

    @Test("reconcile drops an announcement whose state reverted during the window")
    func reconcileDropsStaleAnnouncement() {
        let staleID = UUID()
        let liveID = UUID()
        let stale = WorkspaceAttentionAnnouncementTracker.Announcement(
            sessionID: staleID, title: "acked", agentKind: .codex, state: .needsAttention
        )
        let live = WorkspaceAttentionAnnouncementTracker.Announcement(
            sessionID: liveID, title: "still", agentKind: .claudeCode, state: .needsAttention
        )

        // The user acked `staleID` inside the 500ms window → its live lookup
        // returns nil, so it must not be spoken.
        let reconciled = WorkspaceAttentionAnnouncementTracker.reconcile(
            [stale, live]
        ) { sessionID in sessionID == liveID ? live : nil }

        #expect(reconciled.map(\.sessionID) == [liveID])
        #expect(
            WorkspaceAttentionAnnouncementTracker.spokenAnnouncement(for: reconciled)
                == "Claude Code in still needs input."
        )
    }

    @Test("two close-together announcements both survive the drain when both stay live")
    func twoCloseTogetherAnnouncementsBothSurvive() {
        // Item 1 (INT-504 R2): the app-layer drain no longer resets its window on
        // every new crossing, so an earlier valid announcement can't be starved
        // past its own window and dropped. At the reconcile boundary both distinct
        // workspaces — queued close together in the same window — survive and the
        // count reflects both.
        let firstID = UUID()
        let secondID = UUID()
        let first = WorkspaceAttentionAnnouncementTracker.Announcement(
            sessionID: firstID, title: "one", agentKind: .codex, state: .needsAttention
        )
        let second = WorkspaceAttentionAnnouncementTracker.Announcement(
            sessionID: secondID, title: "two", agentKind: .claudeCode, state: .done
        )

        let reconciled = WorkspaceAttentionAnnouncementTracker.reconcile([first, second]) { id in
            id == firstID ? first : (id == secondID ? second : nil)
        }

        #expect(reconciled.map(\.sessionID) == [firstID, secondID])
        #expect(
            WorkspaceAttentionAnnouncementTracker.spokenAnnouncement(for: reconciled)
                == "2 workspaces need attention."
        )
    }

    @Test("reconcile rebuilds the spoken message from the live announcement")
    func reconcileRebuildsFromLiveAnnouncement() {
        // Item 2 (INT-504 R2): the enqueued announcement captured title/kind at
        // crossing time. If the winning pane/kind/title changed while the rollup
        // stayed announce-worthy, the LIVE values must be spoken, not the stale
        // captured ones. `reconcile` rebuilds from the live announcement.
        let sessionID = UUID()
        let stale = WorkspaceAttentionAnnouncementTracker.Announcement(
            sessionID: sessionID, title: "old title", agentKind: .codex, state: .needsAttention
        )
        // Live rollup now: title renamed, winning agent flipped to Claude Code,
        // still announce-worthy.
        let live = WorkspaceAttentionAnnouncementTracker.Announcement(
            sessionID: sessionID, title: "new title", agentKind: .claudeCode, state: .needsAttention
        )

        let reconciled = WorkspaceAttentionAnnouncementTracker.reconcile([stale]) { id in
            id == sessionID ? live : nil
        }

        #expect(reconciled.count == 1)
        #expect(reconciled.first?.title == "new title")
        #expect(reconciled.first?.agentKind == .claudeCode)
        #expect(
            WorkspaceAttentionAnnouncementTracker.spokenAnnouncement(for: reconciled)
                == "Claude Code in new title needs input."
        )
    }

    @Test("reconcile drops an announcement whose workspace is no longer announce-worthy")
    func reconcileDropsWhenLiveIsNil() {
        // The user acked the prompt within the window → the live lookup returns
        // nil → the announcement is dropped (no stale "needs input").
        let stale = WorkspaceAttentionAnnouncementTracker.Announcement(
            sessionID: UUID(), title: "acked", agentKind: .codex, state: .needsAttention
        )
        let reconciled = WorkspaceAttentionAnnouncementTracker.reconcile([stale]) { _ in nil }
        #expect(reconciled.isEmpty)
    }

    @Test("does not announce a processError crossing already spoken by the specific sibling-pane-exit announcer")
    func skipsDuplicateProcessErrorAnnouncement() {
        // INT-642: recordSiblingPaneExitError sets attentionReason = .processError,
        // which collapses to the generic .needsAttention rollup state — the SAME
        // event TerminalAccessibilityAnnouncer.announceSiblingPaneExitError already
        // spoke specifically ("pane exited with error"). The tracker must not also
        // speak the generic "needs input" for it.
        let selected = session(title: "active", kind: .shell, state: .idle)
        let background = session(title: "agent", kind: .codex, state: .running)
        var tracker = WorkspaceAttentionAnnouncementTracker(groups: [
            SessionGroup(name: "main", sessions: [selected, background])
        ])

        let backgroundProcessError = TerminalSession(
            id: background.id,
            title: "agent",
            workingDirectory: "~",
            agentKind: .codex,
            attentionReason: .processError
        )
        let announcements = tracker.announcements(
            afterUpdating: [SessionGroup(name: "main", sessions: [selected, backgroundProcessError])],
            selectedSessionID: selected.id,
            isAppActive: true
        )

        #expect(announcements.isEmpty)
    }

    @Test("still announces a needsAttention crossing for a non-processError reason")
    func announcesNonProcessErrorNeedsAttention() {
        // Guards the dedup from over-suppressing: bell/permissionPrompt/etc never
        // got a specific announcement elsewhere, so they must still be spoken.
        let selected = session(title: "active", kind: .shell, state: .idle)
        let background = session(title: "agent", kind: .codex, state: .running)
        var tracker = WorkspaceAttentionAnnouncementTracker(groups: [
            SessionGroup(name: "main", sessions: [selected, background])
        ])

        let backgroundPrompt = TerminalSession(
            id: background.id,
            title: "agent",
            workingDirectory: "~",
            agentKind: .codex,
            attentionReason: .permissionPrompt
        )
        let announcements = tracker.announcements(
            afterUpdating: [SessionGroup(name: "main", sessions: [selected, backgroundPrompt])],
            selectedSessionID: selected.id,
            isAppActive: true
        )

        #expect(announcements.count == 1)
        #expect(announcements.first?.state == .needsAttention)
    }

    @Test("still announces when a processError pane sits beside a non-processError attention pane")
    func announcesMixedAttentionReasonsAcrossPanes() {
        // PR #376 review: all attention reasons share one .needsAttention
        // priority tier, so a .processError pane can win the traversal-order
        // tie over a .permissionPrompt sibling nobody announces specifically.
        // The dedup must be per-pane: suppress only when EVERY attention pane
        // is .processError.
        let selected = session(title: "active", kind: .shell, state: .idle)
        let quietA = TerminalPane(title: "a", workingDirectory: "~", agentKind: .codex, executionPlan: .local)
        let quietB = TerminalPane(title: "b", workingDirectory: "~", agentKind: .codex, executionPlan: .local)
        let sessionID = UUID()
        func splitSession(_ first: TerminalPane, _ second: TerminalPane) -> TerminalSession {
            TerminalSession(
                id: sessionID,
                title: "agent",
                workingDirectory: "~",
                layout: .split(
                    TerminalSplit(
                        orientation: .horizontal, first: .pane(first), second: .pane(second)
                    ))
            )
        }
        var tracker = WorkspaceAttentionAnnouncementTracker(groups: [
            SessionGroup(name: "main", sessions: [selected, splitSession(quietA, quietB)])
        ])

        var crashed = quietA
        crashed.attentionReason = .processError
        var prompting = quietB
        prompting.attentionReason = .permissionPrompt
        let announcements = tracker.announcements(
            afterUpdating: [
                SessionGroup(name: "main", sessions: [selected, splitSession(crashed, prompting)])
            ],
            selectedSessionID: selected.id,
            isAppActive: true
        )

        #expect(announcements.count == 1)
        #expect(announcements.first?.state == .needsAttention)
    }

    @Test("a same-window burst collapses to a count")
    func burstCollapsesToCount() {
        let a = WorkspaceAttentionAnnouncementTracker.Announcement(
            sessionID: UUID(), title: "one", agentKind: .codex, state: .needsAttention
        )
        let b = WorkspaceAttentionAnnouncementTracker.Announcement(
            sessionID: UUID(), title: "two", agentKind: .claudeCode, state: .done
        )
        #expect(
            WorkspaceAttentionAnnouncementTracker.spokenAnnouncement(for: [a, b])
                == "2 workspaces need attention."
        )
        #expect(WorkspaceAttentionAnnouncementTracker.spokenAnnouncement(for: []) == nil)
    }
}
