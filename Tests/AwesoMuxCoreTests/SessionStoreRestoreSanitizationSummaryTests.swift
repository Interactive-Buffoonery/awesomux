import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("SessionStore restore sanitization summary")
struct SessionStoreRestoreSanitizationSummaryTests {
    @Test("clean snapshot restores without a sanitization summary")
    func cleanSnapshotHasEmptySummary() {
        let session = Self.makeSession()
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "awesoMux", sessions: [session])],
            selectedSessionID: session.id
        )

        let restored = SessionStore.restore(from: snapshot)

        #expect(restored.sanitizationSummary.isEmpty)
        #expect(restored.sanitizationSummary.totalAdjustments == 0)
        #expect(restored.store.selectedSessionID == session.id)
    }

    @Test("invalid pane working directory restores to home and records pane adjustment")
    func invalidPaneWorkingDirectoryRecordsAdjustment() throws {
        let pane = TerminalPane(
            title: "pane",
            workingDirectory: "/tmp/remote-controlled",
            executionPlan: .local
        )
        let session = Self.makeSession(
            layout: .pane(pane),
            activePaneID: pane.id
        )

        let restored = SessionStore.restore(from: Self.snapshot(with: session))
        let restoredPane = try #require(restored.store.selectedSession?.activePane)

        #expect(restoredPane.workingDirectory == "~")
        #expect(restored.sanitizationSummary.paneWorkingDirectoryAdjustments == 1)
        #expect(restored.sanitizationSummary.sessionWorkingDirectoryAdjustments == 0)
    }

    @Test("dirty multi-pane session and pane titles each record a title adjustment")
    func dirtyTitlesRecordAdjustments() throws {
        // A multi-pane session's title is a distinct sidebar datum from its pane
        // titles, so both are genuinely separate cleanups.
        let pane = TerminalPane(title: "pane\u{202E}", workingDirectory: "~", executionPlan: .local)
        let sibling = TerminalPane(title: "sibling", workingDirectory: "~", executionPlan: .local)
        let session = Self.makeSession(
            title: "\u{200E}",
            layout: .split(TerminalSplit(
                orientation: .horizontal,
                first: .pane(pane),
                second: .pane(sibling)
            )),
            activePaneID: pane.id
        )

        let restored = SessionStore.restore(from: Self.snapshot(with: session))
        let restoredSession = try #require(restored.store.selectedSession)

        #expect(restoredSession.title == "shell 1")
        #expect(restoredSession.activePane?.title == "pane")
        #expect(restored.sanitizationSummary.sessionTitleAdjustments == 1)
        #expect(restored.sanitizationSummary.paneTitleAdjustments == 1)
    }

    @Test("single-pane dirty title is counted once, not doubled")
    func singlePaneDirtyTitleCountedOnce() throws {
        // A single-pane session synthesizes its root pane from the session
        // title, so session.title == pane.title — one user-visible cleanup, not
        // two. Counting it at both levels would inflate the reported total.
        let session = Self.makeSession(title: "proj\u{202E}")

        let restored = SessionStore.restore(from: Self.snapshot(with: session))
        let restoredSession = try #require(restored.store.selectedSession)

        #expect(restoredSession.title == "proj")
        #expect(restored.sanitizationSummary.sessionTitleAdjustments == 0)
        #expect(restored.sanitizationSummary.paneTitleAdjustments == 1)
        #expect(restored.sanitizationSummary.changedItemCount == 1)
    }

    @Test("dirty group name records group name adjustment")
    func dirtyGroupNameRecordsAdjustment() {
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "ops\u{202E}", sessions: [Self.makeSession()])],
            selectedSessionID: nil
        )

        let restored = SessionStore.restore(from: snapshot)

        #expect(restored.store.groups.first?.name == "ops")
        #expect(restored.sanitizationSummary.groupNameAdjustments == 1)
        #expect(restored.sanitizationSummary.droppedGroups == 0)
    }

    @Test("mixed-script group name records adjustment, never a drop")
    func mixedScriptGroupNameRecordsAdjustmentNotDrop() {
        let snapshot = SessionSnapshot(
            groups: [
                SessionGroup(
                    name: "\u{0421}l\u{0430}ud\u{0435}",
                    sessions: [Self.makeSession()]
                )
            ],
            selectedSessionID: nil
        )

        let restored = SessionStore.restore(from: snapshot)

        #expect(
            restored.store.groups.map(\.name)
                == [SessionStore.canonicalDefaultGroupName]
        )
        #expect(restored.store.groups.first?.sessions.count == 1)
        #expect(restored.sanitizationSummary.groupNameAdjustments == 1)
        #expect(restored.sanitizationSummary.droppedGroups == 0)
    }

    @Test("two mixed-script groups quarantine and merge into one canonical group")
    func twoMixedScriptGroupsQuarantineAndMerge() {
        let first = Self.makeSession(title: "first")
        let second = Self.makeSession(title: "second")
        let snapshot = SessionSnapshot(
            groups: [
                // Distinct confusable names: Cyrillic-in-Latin and
                // Greek-plus-Cyrillic. Both quarantine to the canonical
                // default, then the ordinary merge path folds them together.
                SessionGroup(name: "\u{0421}l\u{0430}ud\u{0435}", sessions: [first]),
                SessionGroup(name: "\u{0391}\u{0430}", sessions: [second])
            ],
            selectedSessionID: nil
        )

        let restored = SessionStore.restore(from: snapshot)

        #expect(
            restored.store.groups.map(\.name)
                == [SessionStore.canonicalDefaultGroupName]
        )
        #expect(
            restored.store.groups.first?.sessions.map(\.title)
                == ["first", "second"]
        )
        #expect(restored.sanitizationSummary.groupNameAdjustments == 2)
        #expect(restored.sanitizationSummary.mergedGroups == 1)
        #expect(restored.sanitizationSummary.droppedGroups == 0)
    }

    @Test("group name that sanitizes to empty records dropped group")
    func emptyGroupNameRecordsDroppedGroup() {
        let valid = SessionGroup(name: "valid", sessions: [Self.makeSession(title: "valid")])
        let dropped = SessionGroup(name: "\u{200E}", sessions: [Self.makeSession(title: "dropped")])
        let snapshot = SessionSnapshot(
            groups: [dropped, valid],
            selectedSessionID: nil
        )

        let restored = SessionStore.restore(from: snapshot)

        #expect(restored.store.groups.map(\.name) == ["valid"])
        #expect(restored.sanitizationSummary.droppedGroups == 1)
    }

    @Test("groups with colliding sanitized names merge and record merge")
    func collidingGroupsMergeAndRecordMerge() {
        let first = Self.makeSession(title: "first")
        let second = Self.makeSession(title: "second")
        let snapshot = SessionSnapshot(
            groups: [
                SessionGroup(name: "scratch", sessions: [first]),
                SessionGroup(name: "scratch\u{202E}", sessions: [second])
            ],
            selectedSessionID: nil
        )

        let restored = SessionStore.restore(from: snapshot)

        #expect(restored.store.groups.count == 1)
        #expect(restored.store.groups.first?.name == "scratch")
        #expect(restored.store.groups.first?.sessions.map(\.title) == ["first", "second"])
        #expect(restored.sanitizationSummary.mergedGroups == 1)
    }

    @Test("all groups dropped restores empty and records dropped group")
    func allGroupsDroppedRestoresEmptyAndRecordsDroppedGroup() {
        let snapshot = SessionSnapshot(
            groups: [
                SessionGroup(name: "\u{200E}", sessions: [Self.makeSession()])
            ],
            selectedSessionID: nil
        )

        let restored = SessionStore.restore(from: snapshot)

        #expect(restored.store.groups.isEmpty)
        #expect(restored.store.selectedSessionID == nil)
        #expect(restored.sanitizationSummary.droppedGroups == 1)
    }

    @Test("missing persisted selected session records selected-session fallback")
    func missingSelectedSessionRecordsFallback() {
        let session = Self.makeSession()
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "awesoMux", sessions: [session])],
            selectedSessionID: UUID()
        )

        let restored = SessionStore.restore(from: snapshot)

        #expect(restored.store.selectedSessionID == session.id)
        #expect(restored.sanitizationSummary.selectedSessionFallbacks == 1)
    }

    @Test("missing active pane records active-pane fallback")
    func missingActivePaneRecordsFallback() throws {
        let pane = TerminalPane(title: "pane", workingDirectory: "~", executionPlan: .local)
        var session = Self.makeSession(
            layout: .pane(pane),
            activePaneID: pane.id
        )
        session.activePaneID = UUID()

        let restored = SessionStore.restore(from: Self.snapshot(with: session))
        let restoredSession = try #require(restored.store.selectedSession)

        #expect(restoredSession.activePaneID == pane.id)
        #expect(restored.sanitizationSummary.activePaneFallbacks == 1)
    }

    @Test("over-depth layout collapses and records collapsed layout")
    func overDepthLayoutRecordsCollapse() throws {
        let leaf = TerminalPane(title: "deep", workingDirectory: "~", executionPlan: .local)
        let session = Self.makeSession(
            layout: Self.layout(depth: 70, leaf: leaf),
            activePaneID: leaf.id
        )

        let restored = SessionStore.restore(from: Self.snapshot(with: session))
        let restoredSession = try #require(restored.store.selectedSession)

        #expect(restoredSession.layout.isSinglePane)
        #expect(restored.sanitizationSummary.collapsedLayouts == 1)
    }

    @Test("structural ID reassignment archives but produces no user-visible warning")
    func structuralIDReassignmentArchivesWithoutWarning() throws {
        let duplicateSessionID = UUID()
        let firstPane = TerminalPane(title: "first", workingDirectory: "~", executionPlan: .local)
        let secondPane = TerminalPane(title: "second", workingDirectory: "~", executionPlan: .local)
        let first = Self.makeSession(
            id: duplicateSessionID,
            title: "first",
            agentState: .running,
            unreadNotificationCount: 3,
            layout: .pane(firstPane),
            activePaneID: firstPane.id
        )
        let second = Self.makeSession(
            id: duplicateSessionID,
            title: "second",
            layout: .pane(secondPane),
            activePaneID: secondPane.id
        )
        let staleClosedPane = TerminalPane(title: "stale", workingDirectory: "~", executionPlan: .local)
        let staleRecentlyClosed = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "stale",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .pane(staleClosedPane),
            activePaneID: staleClosedPane.id,
            groupID: UUID(),
            groupName: "awesoMux",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date().addingTimeInterval(-(SessionStore.recentlyClosedTTL + 60))
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "awesoMux", sessions: [first, second])],
            selectedSessionID: nil,
            recentlyClosed: [staleRecentlyClosed]
        )

        let restored = SessionStore.restore(from: snapshot)
        let restoredSessions = restored.store.groups.flatMap(\.sessions)

        // Duplicate IDs are rewritten: this alters the persisted graph (so it
        // must trigger a recovery archive — isEmpty is false), but it's not a
        // user-perceivable change, so it produces no severity line.
        #expect(!restored.sanitizationSummary.isEmpty)
        #expect(restored.sanitizationSummary.idReassignments == 1)
        #expect(!restored.sanitizationSummary.hasUserVisibleAdjustments)
        #expect(restored.sanitizationSummary.severitySummaryLines.isEmpty)
        #expect(Set(restoredSessions.map(\.id)).count == 2)
        #expect(restoredSessions.first?.agentState == .idle)
        #expect(restored.store.unreadNotificationTotal == 0)
        #expect(restored.store.recentlyClosed.isEmpty)
    }

    @Test("empty summary has no severity lines")
    func emptySummaryHasNoSeverityLines() {
        let summary = SessionRestoreSanitizationSummary()

        #expect(summary.severitySummaryLines.isEmpty)
    }

    @Test("removed counters produce removed severity line")
    func removedCountersProduceRemovedSeverityLine() {
        let summary = SessionRestoreSanitizationSummary(droppedGroups: 1, collapsedLayouts: 1)

        #expect(summary.removedItemCount == 2)
        #expect(summary.severitySummaryLines == [
            "2 items could not be restored and were removed."
        ])
    }

    @Test("changed counters produce changed severity line")
    func changedCountersProduceChangedSeverityLine() {
        let summary = SessionRestoreSanitizationSummary(
            groupNameAdjustments: 1,
            paneWorkingDirectoryAdjustments: 1
        )

        #expect(summary.changedItemCount == 2)
        #expect(summary.severitySummaryLines == [
            "2 items were cleaned up, such as invalid names or paths."
        ])
    }

    @Test("fallback counters produce fallback severity line")
    func fallbackCountersProduceFallbackSeverityLine() {
        let summary = SessionRestoreSanitizationSummary(
            activePaneFallbacks: 1,
            selectedSessionFallbacks: 1
        )

        #expect(summary.fallbackItemCount == 2)
        #expect(summary.severitySummaryLines == [
            "2 fallback values were used."
        ])
    }

    @Test("singular grammar works for severity lines")
    func singularGrammarWorksForSeverityLines() {
        let removed = SessionRestoreSanitizationSummary(droppedGroups: 1)
        let changed = SessionRestoreSanitizationSummary(groupNameAdjustments: 1)
        let fallback = SessionRestoreSanitizationSummary(activePaneFallbacks: 1)

        #expect(removed.severitySummaryLines == [
            "1 item could not be restored and was removed."
        ])
        #expect(changed.severitySummaryLines == [
            "1 item was cleaned up, such as invalid names or paths."
        ])
        #expect(fallback.severitySummaryLines == [
            "1 fallback value was used."
        ])
    }

    @Test("multiple categories produce ordered multi-line severity")
    func multipleCategoriesProduceOrderedSeverityLines() {
        let summary = SessionRestoreSanitizationSummary(
            groupNameAdjustments: 1,
            droppedGroups: 1,
            selectedSessionFallbacks: 1
        )

        #expect(summary.severitySummaryLines == [
            "1 item could not be restored and was removed.",
            "1 item was cleaned up, such as invalid names or paths.",
            "1 fallback value was used."
        ])
    }

    @Test("a snapshot dirty in many ways tallies every counter")
    func kitchenSinkCombinesCountersCorrectly() {
        let dirtyTitlePane = TerminalPane(title: "p\u{202E}", workingDirectory: "~", executionPlan: .local)
        let badCwdPane = TerminalPane(title: "ok", workingDirectory: "/tmp/escape", executionPlan: .local)
        let multiPaneSession = Self.makeSession(
            title: "s\u{202E}",
            layout: .split(TerminalSplit(
                orientation: .horizontal,
                first: .pane(dirtyTitlePane),
                second: .pane(badCwdPane)
            )),
            activePaneID: dirtyTitlePane.id
        )
        let snapshot = SessionSnapshot(
            groups: [
                SessionGroup(name: "ops\u{202E}", sessions: [multiPaneSession]),
                SessionGroup(name: "ops", sessions: [Self.makeSession(title: "b")]),
                SessionGroup(name: "\u{200E}", sessions: [Self.makeSession(title: "dropped")])
            ],
            selectedSessionID: UUID()
        )

        let summary = SessionStore.restore(from: snapshot).sanitizationSummary

        #expect(summary.groupNameAdjustments == 1)
        #expect(summary.droppedGroups == 1)
        #expect(summary.mergedGroups == 1)
        #expect(summary.sessionTitleAdjustments == 1)
        #expect(summary.paneTitleAdjustments == 1)
        #expect(summary.paneWorkingDirectoryAdjustments == 1)
        #expect(summary.selectedSessionFallbacks == 1)
        #expect(summary.sessionWorkingDirectoryAdjustments == 0)
    }

    @Test("title adjustments accumulate across multiple dirty items")
    func titleAdjustmentsAccumulate() {
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "g", sessions: [
                Self.makeSession(title: "a\u{202E}"),
                Self.makeSession(title: "b\u{202E}"),
                Self.makeSession(title: "c\u{202E}")
            ])],
            selectedSessionID: nil
        )

        let summary = SessionStore.restore(from: snapshot).sanitizationSummary

        #expect(summary.paneTitleAdjustments == 3)
        #expect(summary.sessionTitleAdjustments == 0)
    }

    @Test("empty groups array restores as an empty workspace tree")
    func emptyGroupsArrayRestoresEmpty() {
        let restored = SessionStore.restore(
            from: SessionSnapshot(groups: [], selectedSessionID: nil)
        )

        #expect(restored.sanitizationSummary.droppedGroups == 0)
        #expect(restored.store.groups.isEmpty)
        #expect(restored.store.selectedSessionID == nil)
    }

    @Test("all groups dropped with a stale selection does not count selection fallback")
    func allGroupsDroppedDoesNotCountSelectionFallback() {
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "\u{200E}", sessions: [Self.makeSession()])],
            selectedSessionID: UUID()
        )

        let summary = SessionStore.restore(from: snapshot).sanitizationSummary

        #expect(summary.selectedSessionFallbacks == 0)
        #expect(summary.fallbackItemCount == 0)
    }

    @Test("benign path normalization is not counted as a cleanup")
    func benignNormalizationNotCounted() throws {
        // A valid home path that only changes via standardization (a dropped
        // trailing slash) must not be reported to the user as "cleaned up."
        let pane = TerminalPane(title: "ok", workingDirectory: "~/Documents/", executionPlan: .local)
        let session = Self.makeSession(layout: .pane(pane), activePaneID: pane.id)

        let restored = SessionStore.restore(from: Self.snapshot(with: session))

        #expect(restored.store.selectedSession?.activePane?.workingDirectory == "~/Documents")
        #expect(restored.sanitizationSummary.paneWorkingDirectoryAdjustments == 0)
        #expect(restored.sanitizationSummary.isEmpty)
    }

    private static func snapshot(with session: TerminalSession) -> SessionSnapshot {
        SessionSnapshot(
            groups: [SessionGroup(name: "awesoMux", sessions: [session])],
            selectedSessionID: session.id
        )
    }

    private static func makeSession(
        id: TerminalSession.ID = UUID(),
        title: String = "shell",
        workingDirectory: String = "~",
        agentKind: AgentKind = .shell,
        agentState: AgentState = .idle,
        unreadNotificationCount: Int = 0,
        layout: TerminalPaneLayout? = nil,
        activePaneID: TerminalPane.ID? = nil
    ) -> TerminalSession {
        TerminalSession(
            id: id,
            title: title,
            workingDirectory: workingDirectory,
            agentKind: agentKind,
            agentState: agentState,
            unreadNotificationCount: unreadNotificationCount,
            layout: layout,
            activePaneID: activePaneID
        )
    }

    private static func layout(depth: Int, leaf: TerminalPane) -> TerminalPaneLayout {
        var layout = TerminalPaneLayout.pane(leaf)
        for index in 0..<depth {
            layout = .split(TerminalSplit(
                orientation: index.isMultiple(of: 2) ? .horizontal : .vertical,
                first: layout,
                second: .pane(TerminalPane(
                    title: "sibling \(index)",
                            workingDirectory: "~",
                            executionPlan: .local
                ))
            ))
        }
        return layout
    }
}
