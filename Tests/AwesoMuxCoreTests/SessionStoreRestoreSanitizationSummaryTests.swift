import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("SessionStore restore sanitization summary")
struct SessionStoreRestoreSanitizationSummaryTests {

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

        #expect(!restored.sanitizationSummary.isEmpty)
        #expect(restored.sanitizationSummary.hasUserVisibleAdjustments)
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

        #expect(!restored.sanitizationSummary.isEmpty)
        #expect(restored.sanitizationSummary.hasUserVisibleAdjustments)
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

        #expect(!restored.sanitizationSummary.isEmpty)
        #expect(restored.sanitizationSummary.hasUserVisibleAdjustments)
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

        #expect(!restored.sanitizationSummary.isEmpty)
        #expect(restored.sanitizationSummary.hasUserVisibleAdjustments)
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

        #expect(!restored.sanitizationSummary.isEmpty)
        #expect(restored.sanitizationSummary.hasUserVisibleAdjustments)
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
        #expect(Set(restoredSessions.map(\.id)).count == 2)
        #expect(restoredSessions.first?.agentState == .idle)
        #expect(restored.store.unreadNotificationTotal == 0)
        #expect(restored.store.recentlyClosed.isEmpty)

        #expect(!restored.sanitizationSummary.isEmpty)
        #expect(!restored.sanitizationSummary.hasUserVisibleAdjustments)
    }

    @Test("clean and normalized snapshots need no cleanup", arguments: [false, true])
    func benignNormalizationNotCounted(normalize: Bool) throws {
        // A valid home path that only changes via standardization (a dropped
        // trailing slash) must not be reported to the user as "cleaned up."
        let pane = TerminalPane(title: "ok", workingDirectory: normalize ? "~/Documents/" : "~", executionPlan: .local)
        let session = Self.makeSession(layout: .pane(pane), activePaneID: pane.id)

        let restored = SessionStore.restore(from: Self.snapshot(with: session))

        #expect(restored.store.selectedSessionID == session.id)
        #expect(restored.store.selectedSession?.activePane?.workingDirectory == (normalize ? "~/Documents" : "~"))

        #expect(restored.sanitizationSummary.isEmpty)
        #expect(!restored.sanitizationSummary.hasUserVisibleAdjustments)
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
