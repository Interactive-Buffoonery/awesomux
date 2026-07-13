import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("RecentlyClosedWorkspaceReducer")
struct RecentlyClosedWorkspaceReducerTests {
    @Test("reopen preserves structured synthetic title metadata")
    func reopenPreservesSyntheticTitleMetadata() throws {
        let groupID = UUID()
        let pane = TerminalPane(title: "shell", workingDirectory: "/work", executionPlan: .local)
        let syntheticTitle = SyntheticSessionTitle(agentKind: .shell, index: 4)
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: syntheticTitle.canonicalTitle,
            syntheticTitle: syntheticTitle,
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .pane(pane),
            activePaneID: pane.id,
            groupID: groupID,
            groupName: "main",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date(timeIntervalSince1970: 10)
        )
        var groups = [SessionGroup(id: groupID, name: "main", sessions: [])]
        var recentlyClosed = [entry]
        var transient: RecentlyClosedWorkspace?

        _ = try #require(RecentlyClosedWorkspaceReducer.reopenMostRecentlyClosed(
            in: &groups,
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &transient,
            now: Date(timeIntervalSince1970: 11)
        ))

        #expect(groups[0].sessions[0].syntheticTitle == syntheticTitle)
        #expect(groups[0].sessions[0].title == "shell 4")
    }

    @Test("reopen reallocates synthetic title metadata that a live workspace reused")
    func reopenReallocatesCollidingSyntheticTitleMetadata() throws {
        let groupID = UUID()
        let reusedTitle = SyntheticSessionTitle(agentKind: .shell, index: 2)
        let closedPane = TerminalPane(title: "shell", workingDirectory: "/closed", executionPlan: .local)
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: reusedTitle.canonicalTitle,
            syntheticTitle: reusedTitle,
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
        let firstTitle = SyntheticSessionTitle(agentKind: .shell, index: 1)
        let first = TerminalSession(
            title: firstTitle.canonicalTitle,
            workingDirectory: "/first",
            syntheticTitle: firstTitle,
            agentKind: .shell
        )
        let reused = TerminalSession(
            title: reusedTitle.canonicalTitle,
            workingDirectory: "/replacement",
            syntheticTitle: reusedTitle,
            agentKind: .shell
        )
        var groups = [SessionGroup(id: groupID, name: "main", sessions: [first, reused])]
        var recentlyClosed = [entry]
        var transient: RecentlyClosedWorkspace?

        let reopenedID = try #require(RecentlyClosedWorkspaceReducer.reopenMostRecentlyClosed(
            in: &groups,
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &transient,
            now: Date(timeIntervalSince1970: 11)
        ))

        let reopened = try #require(groups[0].sessions.first { $0.id == reopenedID })
        #expect(reopened.syntheticTitle == SyntheticSessionTitle(agentKind: .shell, index: 3))
        #expect(reopened.title == "shell 3")
        #expect(Set(groups[0].sessions.compactMap(\.syntheticTitle)).count == 3)
    }

    @Test("reopen picks newest tier, drains twins, mints a fresh session id, preserves the pane id")
    func reopenPicksNewestTierAndRemapsIDs() throws {
        let groupID = UUID()
        let pane = TerminalPane(title: "pane", workingDirectory: "/work", executionPlan: .local)
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "workspace",
            isTitleUserEdited: true,
            agentKind: .codex,
            layout: .pane(pane),
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

        let reopenedID = try #require(RecentlyClosedWorkspaceReducer.reopenMostRecentlyClosed(
            in: &groups,
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &transient,
            now: Date(timeIntervalSince1970: 11)
        ))
        let reopened = try #require(groups[0].sessions.first)

        #expect(recentlyClosed.isEmpty)
        #expect(transient == nil)
        #expect(reopened.id == reopenedID)
        #expect(reopened.id != entry.sessionID)
        // The session id is always fresh, but the pane id is preserved (no live
        // collision here) so its daemon + agent event file reattach (INT-578).
        #expect(reopened.activePaneID == pane.id)
        #expect(reopened.workingDirectory == "/work")
    }

    @Test("reopen preserves terminalSessionID + backend metadata so the daemon reattaches (INT-578)")
    func reopenPreservesTerminalSessionIDForDaemonReattach() throws {
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
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "workspace",
            isTitleUserEdited: true,
            agentKind: .codex,
            layout: .pane(pane),
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
        let reopenedPane = try #require(groups[0].sessions.first?.activePane)

        // Both the pane id and the daemon identity must survive: the pane id
        // keys the agent runtime event file and the terminalSessionID keys the
        // daemon socket, so reopen reattaches to the still-running daemon AND
        // keeps receiving its agent events rather than orphaning both (INT-578).
        #expect(reopenedPane.id == pane.id)
        #expect(reopenedPane.terminalSessionID == sessionID)
        #expect(reopenedPane.terminalBackendMetadata == metadata)
    }

    @Test("reopen preserves each pane's daemon identity + metadata across a split (INT-578)")
    func reopenPreservesTerminalSessionIDAcrossSplit() throws {
        let groupID = UUID()
        let firstID = TerminalSessionID(rawValue: "int-578-split-a")!
        let secondID = TerminalSessionID(rawValue: "int-578-split-b")!
        let firstMeta = TerminalBackendMetadata(rawValue: "meta-a")
        let secondMeta = TerminalBackendMetadata(rawValue: "meta-b")
        let first = TerminalPane(
            terminalSessionID: firstID,
            terminalBackendMetadata: firstMeta,
            title: "a",
            workingDirectory: "/a",
            executionPlan: .local
        )
        let second = TerminalPane(
            terminalSessionID: secondID,
            terminalBackendMetadata: secondMeta,
            title: "b",
            workingDirectory: "/b",
            executionPlan: .local
        )
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "split",
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
        var metadataByID: [TerminalSessionID: TerminalBackendMetadata] = [:]
        restoredLayout.forEachPane { metadataByID[$0.terminalSessionID] = $0.terminalBackendMetadata }
        // Each pane keeps its OWN id AND its own metadata — the daemon payload
        // must not cross wires to the sibling pane.
        #expect(metadataByID == [firstID: firstMeta, secondID: secondMeta])
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

    @Test("over-depth entries are consumed without mutating groups")
    func overDepthEntryIsConsumedWithoutReopen() throws {
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
        #expect(recentlyClosed.isEmpty)
        #expect(transient == nil)
    }

    @Test("reopen recreates a deleted remote group with its SSH target (INT-773)")
    func reopenRecreatesDeletedRemoteGroupWithTarget() throws {
        let target = RemoteTarget(user: "ed", host: "pi")
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
            groupRemote: RemoteTarget(user: "ed", host: "old-host"),
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
        let target = RemoteTarget(user: "ed", host: "pi")
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
        let target = RemoteTarget(user: "ed", host: "pi")
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
        let target = RemoteTarget(user: "ed", host: "pi")
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

    @Test("entries without a groupRemote key decode with nil (pre-fix snapshots)")
    func legacyEntryDecodesWithoutGroupRemote() throws {
        let pane = TerminalPane(title: "pane", workingDirectory: "~", executionPlan: .local)
        let modern = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "workspace",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .pane(pane),
            activePaneID: pane.id,
            groupID: UUID(),
            groupName: "group",
            groupRemote: RemoteTarget(user: "ed", host: "pi"),
            indexInGroup: 0,
            closedAt: Date(timeIntervalSince1970: 10)
        )
        var json = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(modern)
        ) as? [String: Any])
        json.removeValue(forKey: "groupRemote")

        let decoded = try JSONDecoder().decode(
            RecentlyClosedWorkspace.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        #expect(decoded.groupRemote == nil)
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
}
