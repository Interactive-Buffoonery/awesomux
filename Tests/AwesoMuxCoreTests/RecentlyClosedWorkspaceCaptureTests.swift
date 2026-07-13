import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("RecentlyClosedWorkspaceReducer capture and recording")
struct RecentlyClosedWorkspaceCaptureTests {
    @Test("isWorthRecording returns true for agent sessions")
    func isWorthRecordingAgentSession() {
        let session = TerminalSession(title: "Codex 1", workingDirectory: "~", agentKind: .codex)
        #expect(RecentlyClosedWorkspaceReducer.isWorthRecording(session))
    }

    @Test("isWorthRecording returns true for user-edited title")
    func isWorthRecordingUserEditedTitle() {
        let session = TerminalSession(
            title: "my project",
            workingDirectory: "~",
            isTitleUserEdited: true,
            agentKind: .shell
        )
        #expect(RecentlyClosedWorkspaceReducer.isWorthRecording(session))
    }

    @Test("isWorthRecording returns true for sessions with unread notifications")
    func isWorthRecordingUnreadNotifications() {
        let session = TerminalSession(
            title: "shell 1",
            workingDirectory: "~",
            agentKind: .shell,
            unreadNotificationCount: 3
        )
        #expect(RecentlyClosedWorkspaceReducer.isWorthRecording(session))
    }

    @Test("isWorthRecording returns true for multi-pane sessions")
    func isWorthRecordingMultiPane() {
        let first = TerminalPane(title: "a", workingDirectory: "~", executionPlan: .local)
        let second = TerminalPane(title: "b", workingDirectory: "~", executionPlan: .local)
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(first),
            second: .pane(second)
        ))
        let session = TerminalSession(
            title: "shell 1",
            workingDirectory: "~",
            agentKind: .shell,
            layout: layout,
            activePaneID: first.id
        )
        #expect(RecentlyClosedWorkspaceReducer.isWorthRecording(session))
    }

    @Test("isWorthRecording returns true for meaningful working directory")
    func isWorthRecordingMeaningfulCwd() {
        let session = TerminalSession(
            title: "shell 1",
            workingDirectory: "/Projects/app",
            agentKind: .shell
        )
        #expect(RecentlyClosedWorkspaceReducer.isWorthRecording(session))
    }

    @Test("isWorthRecording returns true for remote shell sessions")
    func isWorthRecordingRemoteShell() {
        let session = TerminalSession(
            title: "shell 1",
            workingDirectory: "~",
            executionPlan: .ssh(
                SSHExecution(target: RemoteTarget(user: "alice", host: "prod-host")!)
            )
        )
        #expect(RecentlyClosedWorkspaceReducer.isWorthRecording(session))
    }

    @Test("isWorthRecording returns false for vanilla shell session")
    func isWorthRecordingVanillaShell() {
        let session = TerminalSession(
            title: "shell 1",
            workingDirectory: "~",
            agentKind: .shell
        )
        #expect(!RecentlyClosedWorkspaceReducer.isWorthRecording(session))
    }

    @Test("hasMeaningfulWorkingDirectory rejects empty and home")
    func hasMeaningfulWorkingDirectoryRejectsHome() {
        #expect(!RecentlyClosedWorkspaceReducer.hasMeaningfulWorkingDirectory("~"))
        #expect(!RecentlyClosedWorkspaceReducer.hasMeaningfulWorkingDirectory(""))
        #expect(!RecentlyClosedWorkspaceReducer.hasMeaningfulWorkingDirectory("  "))
        // Canonical form — matches what ingest stores and what the reducer
        // compares against (INT-498); raw NSHomeDirectory() would diverge on a
        // symlinked-home machine.
        #expect(
            !RecentlyClosedWorkspaceReducer.hasMeaningfulWorkingDirectory(
                WorkingDirectoryValidator.canonicalHomeDirectory
            )
        )
        #expect(RecentlyClosedWorkspaceReducer.hasMeaningfulWorkingDirectory("/Projects/app"))
    }

    @Test("captureDecision sets shouldPersist based on isWorthRecording")
    func captureDecisionPersistFlag() {
        let group = SessionGroup(name: "main", sessions: [])

        let vanilla = TerminalSession(title: "shell 1", workingDirectory: "~", agentKind: .shell)
        let vanillaDecision = RecentlyClosedWorkspaceReducer.captureDecision(
            session: vanilla,
            group: group,
            indexInGroup: 0,
            now: Date()
        )
        #expect(!vanillaDecision.shouldPersist)

        let agent = TerminalSession(title: "Codex 1", workingDirectory: "~", agentKind: .codex)
        let agentDecision = RecentlyClosedWorkspaceReducer.captureDecision(
            session: agent,
            group: group,
            indexInGroup: 0,
            now: Date()
        )
        #expect(agentDecision.shouldPersist)
    }

    @Test("captureDecision records entry metadata")
    func captureDecisionMetadata() {
        let group = SessionGroup(name: "main", sessions: [])
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: "/work",
            isTitleUserEdited: true,
            agentKind: .codex
        )
        let decision = RecentlyClosedWorkspaceReducer.captureDecision(
            session: session,
            group: group,
            indexInGroup: 2,
            now: Date(timeIntervalSince1970: 100)
        )
        #expect(decision.entry.sessionID == session.id)
        #expect(decision.entry.title == "workspace")
        #expect(decision.entry.agentKind == AgentKind.codex)
        #expect(decision.entry.groupID == group.id)
        #expect(decision.entry.groupName == "main")
        #expect(decision.entry.indexInGroup == 2)
    }

    @Test("capture preserves structured synthetic title metadata")
    func capturePreservesSyntheticTitleMetadata() {
        let syntheticTitle = SyntheticSessionTitle(agentKind: .shell, index: 7)
        let session = TerminalSession(
            title: syntheticTitle.canonicalTitle,
            workingDirectory: "/work",
            syntheticTitle: syntheticTitle,
            agentKind: .shell
        )
        let decision = RecentlyClosedWorkspaceReducer.captureDecision(
            session: session,
            group: SessionGroup(name: "main", sessions: []),
            indexInGroup: 0,
            now: Date()
        )

        #expect(decision.entry.syntheticTitle == syntheticTitle)
    }

    @Test("recordPersisted caps at maxRecentlyClosed and prunes stale entries")
    func recordPersistedCapsAndPrunes() {
        var recentlyClosed: [RecentlyClosedWorkspace] = []
        var transient: RecentlyClosedWorkspace?

        for i in 0..<RecentlyClosedWorkspaceReducer.maxRecentlyClosed + 3 {
            let entry = RecentlyClosedWorkspace(
                sessionID: UUID(),
                title: "session \(i)",
                isTitleUserEdited: true,
                agentKind: .codex,
                layout: .pane(TerminalPane(title: "p", workingDirectory: "~", executionPlan: .local)),
                activePaneID: UUID(),
                groupID: UUID(),
                groupName: "main",
                groupRemote: nil,
                indexInGroup: 0,
                closedAt: Date(timeIntervalSince1970: TimeInterval(i))
            )
            RecentlyClosedWorkspaceReducer.recordPersisted(
                entry,
                recentlyClosed: &recentlyClosed,
                lastClosedTransient: &transient,
                now: Date(timeIntervalSince1970: TimeInterval(i) + 1)
            )
        }

        #expect(recentlyClosed.count == RecentlyClosedWorkspaceReducer.maxRecentlyClosed)
        #expect(transient == nil)
    }

    @Test("prune evicts entries past TTL")
    func pruneEvictsStaleEntries() {
        let now = Date(timeIntervalSince1970: 1000)
        let staleCutoff = now.addingTimeInterval(-RecentlyClosedWorkspaceReducer.recentlyClosedTTL)
        let fresh = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "fresh",
            isTitleUserEdited: true,
            agentKind: .codex,
            layout: .pane(TerminalPane(title: "p", workingDirectory: "~", executionPlan: .local)),
            activePaneID: UUID(),
            groupID: UUID(),
            groupName: "main",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: now.addingTimeInterval(-10)
        )
        let stale = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "stale",
            isTitleUserEdited: true,
            agentKind: .codex,
            layout: .pane(TerminalPane(title: "p", workingDirectory: "~", executionPlan: .local)),
            activePaneID: UUID(),
            groupID: UUID(),
            groupName: "main",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: staleCutoff.addingTimeInterval(-1)
        )
        var recentlyClosed = [stale, fresh]
        var transient: RecentlyClosedWorkspace? = stale

        RecentlyClosedWorkspaceReducer.prune(
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &transient,
            now: now
        )

        #expect(recentlyClosed.count == 1)
        #expect(recentlyClosed[0].title == "fresh")
        #expect(transient == nil)
    }

    @Test("reopen picks persisted entry when it is newer than transient")
    func reopenPicksPersistedWhenNewer() throws {
        let groupID = UUID()
        let pane = TerminalPane(title: "p", workingDirectory: "/work", executionPlan: .local)
        let persistedEntry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "persisted",
            isTitleUserEdited: true,
            agentKind: .codex,
            layout: .pane(pane),
            activePaneID: pane.id,
            groupID: groupID,
            groupName: "main",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date(timeIntervalSince1970: 20)
        )
        let transientEntry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "transient",
            isTitleUserEdited: true,
            agentKind: .codex,
            layout: .pane(TerminalPane(title: "p2", workingDirectory: "/other", executionPlan: .local)),
            activePaneID: UUID(),
            groupID: groupID,
            groupName: "main",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date(timeIntervalSince1970: 10)
        )
        var groups = [SessionGroup(id: groupID, name: "main", sessions: [])]
        var recentlyClosed = [persistedEntry]
        var transient: RecentlyClosedWorkspace? = transientEntry

        let reopenedID = try #require(RecentlyClosedWorkspaceReducer.reopenMostRecentlyClosed(
            in: &groups,
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &transient,
            now: Date(timeIntervalSince1970: 21)
        ))
        let reopened = try #require(groups[0].sessions.first)
        #expect(reopened.id == reopenedID)
        #expect(reopened.title == "persisted")
        #expect(recentlyClosed.isEmpty)
        #expect(transient != nil)
    }

    @Test("reopen returns nil when both tiers are empty")
    func reopenReturnsNilWhenEmpty() {
        var groups = [SessionGroup(name: "main", sessions: [])]
        var recentlyClosed: [RecentlyClosedWorkspace] = []
        var transient: RecentlyClosedWorkspace?

        let result = RecentlyClosedWorkspaceReducer.reopenMostRecentlyClosed(
            in: &groups,
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &transient,
            now: Date()
        )
        #expect(result == nil)
    }

    @Test("reopen creates a destination when groups are empty")
    func reopenCreatesDestinationWhenNoGroups() {
        let groupID = UUID()
        var groups: [SessionGroup] = []
        var recentlyClosed = [RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "entry",
            isTitleUserEdited: true,
            agentKind: .codex,
            layout: .pane(TerminalPane(title: "p", workingDirectory: "~", executionPlan: .local)),
            activePaneID: UUID(),
            groupID: groupID,
            groupName: "main",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date(timeIntervalSince1970: 10)
        )]
        var transient: RecentlyClosedWorkspace?

        let result = RecentlyClosedWorkspaceReducer.reopenMostRecentlyClosed(
            in: &groups,
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &transient,
            now: Date(timeIntervalSince1970: 11)
        )
        #expect(result != nil)
        #expect(recentlyClosed.isEmpty)
        #expect(groups.count == 1)
        #expect(groups[0].id == groupID)
        #expect(groups[0].name == "main")
        #expect(groups[0].sessions.first?.id == result)
    }

    @Test("reopen recreates the missing group when entry groupID has no live match")
    func reopenRecreatesGroupWhenGroupIDMissing() throws {
        let pane = TerminalPane(title: "p", workingDirectory: "/work", executionPlan: .local)
        let missingGroupID = UUID()
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "workspace",
            isTitleUserEdited: true,
            agentKind: .codex,
            layout: .pane(pane),
            activePaneID: pane.id,
            groupID: missingGroupID,
            groupName: "main",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date(timeIntervalSince1970: 10)
        )
        var groups = [SessionGroup(name: "other", sessions: [])]
        var recentlyClosed = [entry]
        var transient: RecentlyClosedWorkspace?

        let reopenedID = try #require(RecentlyClosedWorkspaceReducer.reopenMostRecentlyClosed(
            in: &groups,
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &transient,
            now: Date(timeIntervalSince1970: 11)
        ))
        // The missing group is recreated at the end; the unrelated "other"
        // group is left untouched (INT-166).
        #expect(groups.count == 2)
        #expect(groups[0].sessions.isEmpty)
        #expect(groups[1].id == missingGroupID)
        #expect(groups[1].sessions.first?.id == reopenedID)
    }
}
