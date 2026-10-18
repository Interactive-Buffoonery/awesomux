import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("RecentlyClosedWorkspaceReducer")
struct RecentlyClosedWorkspaceReducerTests {

    @Test("reopen remaps unique document and active references after a live collision")
    func reopenRemapsUniquePaneReferences() throws {
        let groupID = UUID()
        let collidingID = UUID()
        let livePane = TerminalPane(id: collidingID, title: "live", workingDirectory: "/live", executionPlan: .local)
        let liveSession = TerminalSession(
            title: "live",
            workingDirectory: "/live",
            layout: .pane(livePane),
            activePaneID: livePane.id
        )
        let closedPane = TerminalPane(id: collidingID, title: "closed", workingDirectory: "/closed", executionPlan: .local)
        let document = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/reopen-unique.md"),
            title: "reopen-unique.md",
            associatedTerminalPaneID: collidingID
        )
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "closed",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .split(
                TerminalSplit(
                    orientation: .horizontal,
                    first: .documentGroup(DocumentGroup(tabs: [document], selectedTabID: document.id)),
                    second: .pane(closedPane)
                )),
            activePaneID: collidingID,
            groupID: groupID,
            groupName: "main",
            groupRemote: nil,
            indexInGroup: 1,
            closedAt: Date(timeIntervalSince1970: 10)
        )
        var groups = [SessionGroup(id: groupID, name: "main", sessions: [liveSession])]
        var recentlyClosed = [entry]
        var transient: RecentlyClosedWorkspace?

        let reopenedID = try #require(
            RecentlyClosedWorkspaceReducer.reopenMostRecentlyClosed(
                in: &groups,
                recentlyClosed: &recentlyClosed,
                lastClosedTransient: &transient,
                now: Date(timeIntervalSince1970: 11)
            ))
        let reopened = try #require(groups[0].sessions.first { $0.id == reopenedID })
        let reopenedPane = try #require(reopened.layout.firstPane)

        #expect(reopenedPane.id != collidingID)
        #expect(reopened.activePaneID == reopenedPane.id)
        #expect(reopened.layout.firstDocumentGroup?.selectedTab?.associatedTerminalPaneID == reopenedPane.id)
    }

    @Test("reopen preserves each pane daemon and metadata for reattach", arguments: [false, true])
    func reopenPreservesTerminalSessionIDForDaemonReattach(split: Bool) throws {
        let groupID = UUID()
        let sessionID = TerminalSessionID(rawValue: "int-578-daemon")!
        let metadata = TerminalBackendMetadata(rawValue: "backend-state")
        let pane = TerminalPane(
            terminalSessionID: sessionID,
            terminalBackendMetadata: metadata,
            title: "pane",
            workingDirectory: "/work",
            executionPlan: .local
        )
        let sibling = TerminalPane(
            terminalSessionID: TerminalSessionID(rawValue: "int-578-split-b")!,
            terminalBackendMetadata: TerminalBackendMetadata(rawValue: "meta-b"), title: "b", workingDirectory: "/b", executionPlan: .local)
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "workspace",
            isTitleUserEdited: true,
            agentKind: .codex,
            layout: split ? .split(TerminalSplit(orientation: .vertical, first: .pane(pane), second: .pane(sibling))) : .pane(pane),
            activePaneID: pane.id,
            groupID: groupID,
            groupName: "main",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date(timeIntervalSince1970: 10)
        )
        var groups = [SessionGroup(id: groupID, name: "main", sessions: [])]
        var recentlyClosed = [entry]
        var transient: RecentlyClosedWorkspace? = entry

        _ = try #require(RecentlyClosedWorkspaceReducer.reopenMostRecentlyClosed(
            in: &groups,
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &transient,
            now: Date(timeIntervalSince1970: 11)
        ))
        #expect(recentlyClosed.isEmpty)
        #expect(transient == nil)
        #expect(groups[0].sessions.first?.id == entry.sessionID)
        #expect(groups[0].sessions.first?.workingDirectory == "/work")
        let reopenedPane = try #require(groups[0].sessions.first?.activePane)

        // Both the pane id and the daemon identity must survive: the pane id
        // keys the agent runtime event file and the terminalSessionID keys the
        // daemon socket, so reopen reattaches to the still-running daemon AND
        // keeps receiving its agent events rather than orphaning both (INT-578).
        #expect(reopenedPane.id == pane.id)
        #expect(reopenedPane.terminalSessionID == sessionID)
        #expect(reopenedPane.terminalBackendMetadata == metadata)
        if split {
            let reopenedSibling = try #require(groups[0].sessions.first?.layout.pane(id: sibling.id))
            #expect(reopenedSibling.terminalSessionID == sibling.terminalSessionID)
            #expect(reopenedSibling.terminalBackendMetadata == sibling.terminalBackendMetadata)
        }
    }

    @Test("reopen reassigns the second pane when a split's panes self-collide on one id (INT-578)")
    func reopenReassignsSelfCollidingSplitPane() throws {
        // A corrupted snapshot whose two panes carry the SAME stored daemon id,
        // with no live pane involved. The fix's central promise is that such a
        // twin can't drive two panes onto one daemon — exactly one keeps the id,
        // the other is reassigned with its (now-wrong) metadata dropped.
        let groupID = UUID()
        let dup = TerminalSessionID(rawValue: "int-578-self-dup")!
        let first = TerminalPane(
            terminalSessionID: dup,
            terminalBackendMetadata: TerminalBackendMetadata(rawValue: "a"),
            title: "a",
            workingDirectory: "/a",
            executionPlan: .local
        )
        let second = TerminalPane(
            terminalSessionID: dup,
            terminalBackendMetadata: TerminalBackendMetadata(rawValue: "b"),
            title: "b",
            workingDirectory: "/b",
            executionPlan: .local
        )
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "twin",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(first),
                second: .pane(second)
            )),
            activePaneID: first.id,
            groupID: groupID,
            groupName: "main",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date(timeIntervalSince1970: 10)
        )
        var groups = [SessionGroup(id: groupID, name: "main", sessions: [])]
        var recentlyClosed = [entry]
        var transient: RecentlyClosedWorkspace? = entry

        _ = try #require(RecentlyClosedWorkspaceReducer.reopenMostRecentlyClosed(
            in: &groups,
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &transient,
            now: Date(timeIntervalSince1970: 11)
        ))
        let restoredLayout = try #require(groups[0].sessions.first?.layout)
        var restoredPanes: [TerminalPane] = []
        restoredLayout.forEachPane { restoredPanes.append($0) }
        #expect(restoredPanes.count == 2)
        // Exactly one pane keeps the original id; the other gets a fresh unique id.
        #expect(Set(restoredPanes.map(\.terminalSessionID)).count == 2)
        #expect(restoredPanes.contains { $0.terminalSessionID == dup })
        // The reassigned pane can't keep metadata pointing at the other's daemon.
        let reassigned = try #require(restoredPanes.first { $0.terminalSessionID != dup })
        #expect(reassigned.terminalBackendMetadata == .empty)
    }

    @Test("reopen reassigns a terminalSessionID that collides with a live pane (INT-578)")
    func reopenReassignsTerminalSessionIDCollidingWithLivePane() throws {
        let groupID = UUID()
        let sharedID = TerminalSessionID(rawValue: "int-578-collision")!
        // A live pane already drives this daemon. The reopened twin must not
        // alias it — reattaching two panes to one daemon is the aliasing the
        // restore path already guards against.
        let livePane = TerminalPane(
            terminalSessionID: sharedID,
            title: "live",
            workingDirectory: "/live",
            executionPlan: .local
        )
        let liveSession = TerminalSession(
            title: "live",
            workingDirectory: "/live",
            layout: .pane(livePane),
            activePaneID: livePane.id
        )
        let closedPane = TerminalPane(
            terminalSessionID: sharedID,
            terminalBackendMetadata: TerminalBackendMetadata(rawValue: "stale"),
            title: "closed",
            workingDirectory: "/closed",
            executionPlan: .local
        )
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "closed",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .pane(closedPane),
            activePaneID: closedPane.id,
            groupID: groupID,
            groupName: "main",
            groupRemote: nil,
            indexInGroup: 1,
            closedAt: Date(timeIntervalSince1970: 10)
        )
        var groups = [SessionGroup(id: groupID, name: "main", sessions: [liveSession])]
        var recentlyClosed = [entry]
        var transient: RecentlyClosedWorkspace? = entry

        _ = try #require(RecentlyClosedWorkspaceReducer.reopenMostRecentlyClosed(
            in: &groups,
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &transient,
            now: Date(timeIntervalSince1970: 11)
        ))
        let reopenedSession = try #require(groups[0].sessions.last)
        let reopenedPane = try #require(reopenedSession.activePane)
        #expect(reopenedPane.terminalSessionID != sharedID)
        // A reassigned identity can't keep metadata pointing at the live daemon.
        #expect(reopenedPane.terminalBackendMetadata == .empty)
    }

    @Test("reopen drops the daemon when it must remint a pane id colliding with a live pane (INT-578)")
    func reopenReassignsPaneIDCollidingWithLivePane() throws {
        let groupID = UUID()
        // A live pane already owns this UUID — and thus its agent runtime event
        // file. The reopened twin must NOT keep it, or two panes would watch one
        // event file (mirrors restore's pane-id dedup).
        let sharedPaneID = UUID()
        let livePane = TerminalPane(id: sharedPaneID, title: "live", workingDirectory: "/live", executionPlan: .local)
        let liveSession = TerminalSession(
            title: "live",
            workingDirectory: "/live",
            layout: .pane(livePane),
            activePaneID: livePane.id
        )
        // The closed pane's daemon id is unique, but its pane id collides. The
        // daemon's inner agent is still bound to `sharedPaneID`'s event file, so
        // reattaching it would route events to the LIVE pane — the daemon must be
        // dropped (fresh id + empty metadata), not preserved (pane-id/daemon
        // coupling).
        let uniqueDaemon = TerminalSessionID(rawValue: "int-578-pane-collide")!
        let closedPane = TerminalPane(
            id: sharedPaneID,
            terminalSessionID: uniqueDaemon,
            terminalBackendMetadata: TerminalBackendMetadata(rawValue: "stale"),
            title: "closed",
            workingDirectory: "/closed",
            executionPlan: .local
        )
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "closed",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .pane(closedPane),
            activePaneID: closedPane.id,
            groupID: groupID,
            groupName: "main",
            groupRemote: nil,
            indexInGroup: 1,
            closedAt: Date(timeIntervalSince1970: 10)
        )
        var groups = [SessionGroup(id: groupID, name: "main", sessions: [liveSession])]
        var recentlyClosed = [entry]
        var transient: RecentlyClosedWorkspace? = entry

        _ = try #require(RecentlyClosedWorkspaceReducer.reopenMostRecentlyClosed(
            in: &groups,
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &transient,
            now: Date(timeIntervalSince1970: 11)
        ))
        let reopenedPane = try #require(groups[0].sessions.last?.activePane)
        #expect(reopenedPane.id != sharedPaneID)
        // The live pane keeps its id untouched.
        #expect(groups[0].sessions.first?.activePane?.id == sharedPaneID)
        // Daemon identity is COUPLED to the pane id: a reminted pane id can't
        // reattach the old daemon, so it gets a fresh id and dropped metadata.
        #expect(reopenedPane.terminalSessionID != uniqueDaemon)
        #expect(reopenedPane.terminalBackendMetadata == .empty)
    }

    @Test("over-depth entries stay available without mutating groups")
    func overDepthEntryIsPreservedWithoutReopen() throws {
        let groupID = UUID()
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "deep",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: Self.deepLayout(depth: SessionRestoreReducer.maxRestoredLayoutDepth + 1),
            activePaneID: UUID(),
            groupID: groupID,
            groupName: "main",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date(timeIntervalSince1970: 10)
        )
        var groups = [SessionGroup(id: groupID, name: "main", sessions: [])]
        var recentlyClosed = [entry]
        var transient: RecentlyClosedWorkspace? = entry

        let reopenedID = RecentlyClosedWorkspaceReducer.reopenMostRecentlyClosed(
            in: &groups,
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &transient,
            now: Date(timeIntervalSince1970: 11)
        )

        #expect(reopenedID == nil)
        #expect(groups[0].sessions.isEmpty)
        // Reconstruction failed: keep the exact row and LIFO order so reopen
        // remains retryable instead of silently eating the recovery entry.
        #expect(recentlyClosed == [entry])
        #expect(transient == entry)
    }

    @Test("reopen recreates a deleted remote group with its SSH target (INT-773)")
    func reopenRecreatesDeletedRemoteGroupWithTarget() throws {
        let target = RemoteTarget(user: "ed", host: "pi")!
        let pane = TerminalPane(title: "pane", workingDirectory: "~", executionPlan: .local)
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "workspace",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .pane(pane),
            activePaneID: pane.id,
            groupID: UUID(),
            groupName: "remote group",
            groupRemote: target,
            indexInGroup: 0,
            closedAt: Date(timeIntervalSince1970: 10)
        )
        // The owning group was REMOVED after the close — reopen must
        // recreate it, and the recreation must carry the SSH target
        // (previously it came back silently local, INT-773).
        var groups = [SessionGroup(name: "other", sessions: [])]
        var recentlyClosed = [entry]
        var transient: RecentlyClosedWorkspace? = nil

        _ = try #require(RecentlyClosedWorkspaceReducer.reopenMostRecentlyClosed(
            in: &groups,
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &transient,
            now: Date(timeIntervalSince1970: 11)
        ))

        let recreated = try #require(groups.first { $0.id == entry.groupID })
        #expect(recreated.remote == target)
    }

    @Test("reopen into a LIVE group never overwrites that group's remote")
    func reopenIntoLiveGroupLeavesItsRemoteAlone() throws {
        // Entry captured while the group was remote; the live group has since
        // been de-tagged (or re-tagged) — the live group is authoritative, the
        // stale capture must not overwrite it.
        let groupID = UUID()
        let pane = TerminalPane(title: "pane", workingDirectory: "~", executionPlan: .local)
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "workspace",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .pane(pane),
            activePaneID: pane.id,
            groupID: groupID,
            groupName: "group",
            groupRemote: RemoteTarget(user: "ed", host: "old-host")!,
            indexInGroup: 0,
            closedAt: Date(timeIntervalSince1970: 10)
        )
        var groups = [SessionGroup(id: groupID, name: "group", remote: nil, sessions: [])]
        var recentlyClosed = [entry]
        var transient: RecentlyClosedWorkspace? = nil

        _ = try #require(RecentlyClosedWorkspaceReducer.reopenMostRecentlyClosed(
            in: &groups,
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &transient,
            now: Date(timeIntervalSince1970: 11)
        ))

        #expect(groups[0].remote == nil)
    }

    @Test("recreate disambiguates a name collision with a live group (staging -> staging 2)")
    func reopenRecreateDisambiguatesNameCollision() throws {
        // Delete remote "staging", hand-create a LOCAL "staging", then reopen
        // the stale entry: folding into the local group by name would silently
        // re-local-ize the session (the INT-773 bug through the side door),
        // and a duplicate name breaks name-keyed session routing — so the
        // recreated group must disambiguate, mirroring the restore path.
        let target = RemoteTarget(user: "ed", host: "pi")!
        let pane = TerminalPane(title: "pane", workingDirectory: "~", executionPlan: .local)
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "workspace",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .pane(pane),
            activePaneID: pane.id,
            groupID: UUID(),
            groupName: "staging",
            groupRemote: target,
            indexInGroup: 0,
            closedAt: Date(timeIntervalSince1970: 10)
        )
        let localStaging = SessionGroup(name: "staging", sessions: [])
        var groups = [localStaging]
        var recentlyClosed = [entry]
        var transient: RecentlyClosedWorkspace? = nil

        _ = try #require(RecentlyClosedWorkspaceReducer.reopenMostRecentlyClosed(
            in: &groups,
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &transient,
            now: Date(timeIntervalSince1970: 11)
        ))

        let recreated = try #require(groups.first { $0.id == entry.groupID })
        #expect(recreated.name == "staging 2")
        #expect(recreated.remote == target)
        // The pre-existing local group is untouched — no session folded in,
        // no remote applied.
        let untouched = try #require(groups.first { $0.id == localStaging.id })
        #expect(untouched.name == "staging")
        #expect(untouched.remote == nil)
        #expect(untouched.sessions.isEmpty)
    }

    @Test("second entry from the same deleted group ID-folds into the recreated group, no twin")
    func reopenSecondEntryFoldsIntoRecreatedGroup() throws {
        // Pins the ordering guarantee: ID-match runs before any name logic,
        // so after the first entry recreates "staging 2" (keeping the dead
        // group's ID), the sibling entry folds into it — never a "staging 3",
        // and its own captured target is deliberately discarded in favor of
        // the recreated group's.
        let target = RemoteTarget(user: "ed", host: "pi")!
        let deadGroupID = UUID()
        func entry(_ title: String, closedAt: TimeInterval) -> RecentlyClosedWorkspace {
            let pane = TerminalPane(title: title, workingDirectory: "~", executionPlan: .local)
            return RecentlyClosedWorkspace(
                sessionID: UUID(),
                title: title,
                isTitleUserEdited: false,
                agentKind: .shell,
                layout: .pane(pane),
                activePaneID: pane.id,
                groupID: deadGroupID,
                groupName: "staging",
                groupRemote: target,
                indexInGroup: 0,
                closedAt: Date(timeIntervalSince1970: closedAt)
            )
        }
        var groups = [SessionGroup(name: "staging", sessions: [])]
        var recentlyClosed = [entry("newer", closedAt: 20), entry("older", closedAt: 10)]
        var transient: RecentlyClosedWorkspace? = nil

        for _ in 0..<2 {
            _ = try #require(RecentlyClosedWorkspaceReducer.reopenMostRecentlyClosed(
                in: &groups,
                recentlyClosed: &recentlyClosed,
                lastClosedTransient: &transient,
                now: Date(timeIntervalSince1970: 30)
            ))
        }

        #expect(groups.count == 2)
        let recreated = try #require(groups.first { $0.id == deadGroupID })
        #expect(recreated.name == "staging 2")
        #expect(recreated.remote == target)
        #expect(recreated.sessions.count == 2)
    }

    @Test("captureDecision records the owning group's SSH target")
    func captureRecordsGroupRemote() {
        let target = RemoteTarget(user: "ed", host: "pi")!
        let session = TerminalSession(title: "ws", workingDirectory: "~")
        let group = SessionGroup(name: "remote group", remote: target, sessions: [session])

        let decision = RecentlyClosedWorkspaceReducer.captureDecision(
            session: session,
            group: group,
            indexInGroup: 0,
            now: Date(timeIntervalSince1970: 10)
        )

        #expect(decision.entry.groupRemote == target)
    }

    private static func deepLayout(depth: Int) -> TerminalPaneLayout {
        guard depth > 1 else {
            return .pane(TerminalPane(title: "leaf", workingDirectory: "~", executionPlan: .local))
        }
        return .split(TerminalSplit(
            orientation: .vertical,
            first: deepLayout(depth: depth - 1),
                second: .pane(TerminalPane(title: "leaf", workingDirectory: "~", executionPlan: .local))
        ))
    }

    @Test("reopen retains unknown generated document ownership")
    func reopenRetainsUnknownGeneratedDocumentOwnership() throws {
        let tab = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/future-generated.md"),
            title: "Generated Document",
            generatedDocumentKind: .unknown
        )
        let layout = TerminalPaneLayout.documentGroup(
            DocumentGroup(tabs: [tab], selectedTabID: tab.id)
        )
        var seenTerminalSessionIDs: Set<TerminalSessionID> = []
        var seenPaneIDs: Set<TerminalPane.ID> = []

        let reidentified = RecentlyClosedWorkspaceReducer.reidentifiedLayout(
            layout,
            indexHint: 0,
            seenTerminalSessionIDs: &seenTerminalSessionIDs,
            seenPaneIDs: &seenPaneIDs
        )

        let reopened = try #require(reidentified.firstDocumentGroup?.tabs.first)
        #expect(reopened.id != tab.id)
        #expect(reopened.generatedDocumentKind == .unknown)
        #expect(!reopened.isEditable)
    }

    @Test("reopen reserves a discarded daemon id before a later pane")
    func reopenReservesDiscardedDaemonID() {
        let duplicatePaneID = UUID()
        let finalPaneID = UUID()
        let firstDaemon = TerminalSessionID(rawValue: "reopen-ordering-d1")!
        let repeatedDaemon = TerminalSessionID(rawValue: "reopen-ordering-d2")!
        let panes = [
            TerminalPane(
                id: duplicatePaneID,
                terminalSessionID: firstDaemon,
                title: "x1",
                workingDirectory: "/x1",
                executionPlan: .local
            ),
            TerminalPane(
                id: duplicatePaneID,
                terminalSessionID: repeatedDaemon,
                title: "x2",
                workingDirectory: "/x2",
                executionPlan: .local
            ),
            TerminalPane(
                id: finalPaneID,
                terminalSessionID: repeatedDaemon,
                title: "y",
                workingDirectory: "/y",
                executionPlan: .local
            ),
        ]
        var seenDaemons: Set<TerminalSessionID> = []
        var seenPanes: Set<TerminalPane.ID> = []
        let result = RecentlyClosedWorkspaceReducer.reidentifiedLayout(
            Self.layout(for: panes),
            indexHint: 1,
            seenTerminalSessionIDs: &seenDaemons,
            seenPaneIDs: &seenPanes
        )
        var restored: [TerminalPane] = []
        result.forEachPane { restored.append($0) }

        #expect(restored[0].terminalSessionID == firstDaemon)
        #expect(restored[1].terminalSessionID != repeatedDaemon)
        #expect(restored[2].terminalSessionID != repeatedDaemon)
        #expect(Set(restored.map(\.terminalSessionID)).count == 3)
    }

    private static func layout(for panes: [TerminalPane]) -> TerminalPaneLayout {
        panes.dropFirst().reduce(.pane(panes[0])) { layout, pane in
            .split(TerminalSplit(orientation: .horizontal, first: layout, second: .pane(pane)))
        }
    }
}
