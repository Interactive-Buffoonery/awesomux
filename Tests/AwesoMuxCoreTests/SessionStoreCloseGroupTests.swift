import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("SessionStore — Close Group (INT-206)")
struct SessionStoreCloseGroupTests {
    @Test("closing a group closes all its workspaces and removes the group")
    func closeGroupClosesAllWorkspacesAndRemovesGroup() {
        let first = makeSession("first")
        let second = makeSession("second")
        let survivor = makeSession("survivor")
        let doomed = SessionGroup(name: "doomed", sessions: [first, second])
        let kept = SessionGroup(name: "kept", sessions: [survivor])
        let store = SessionStore(groups: [doomed, kept], selectedSessionID: first.id)

        store.closeGroup(id: doomed.id)

        #expect(store.groups.map(\.id) == [kept.id])
        #expect(store.session(id: first.id) == nil)
        #expect(store.session(id: second.id) == nil)
        #expect(store.selectedSession?.id == survivor.id)
    }

    @Test("closing an empty group removes it without touching other groups")
    func closeEmptyGroupRemovesIt() {
        let survivor = makeSession("survivor")
        let empty = SessionGroup(name: "empty", sessions: [])
        let kept = SessionGroup(name: "kept", sessions: [survivor])
        let store = SessionStore(groups: [empty, kept], selectedSessionID: survivor.id)

        store.closeGroup(id: empty.id)

        #expect(store.groups.map(\.id) == [kept.id])
        #expect(store.removeGroup(id: kept.id) == false)
        #expect(store.selectedSession?.id == survivor.id)
    }

    /// Closing the sole group used to leave an empty shell behind, because
    /// `removeGroup` refused the last group. It now removes it outright.
    ///
    /// The `groups.isEmpty` + `selectedSessionID == nil` pair is asserted
    /// together deliberately: that combination is what drives
    /// `SessionDetailView.emptyStateMode` to `.firstLaunch`, which is the
    /// entire reason this destination is acceptable to land on.
    @Test("closing the sole group removes it, leaving an empty tree")
    func closeSoleGroupLeavesEmptyTree() {
        let first = makeSession("first")
        let second = makeSession("second")
        let sole = SessionGroup(name: "sole", sessions: [first, second])
        let store = SessionStore(groups: [sole], selectedSessionID: first.id)

        #expect(store.closeGroup(id: sole.id))

        #expect(store.groups.isEmpty)
        #expect(store.selectedSessionID == nil)
    }

    /// The failure mode most worth fearing when closing the last group became
    /// possible: a restore path that helpfully re-seeds a default group would
    /// make the close look like a silent failure on the next launch, and the
    /// user would have no way to tell that from a bug.
    ///
    /// Runs the REAL persistence shape — encode, decode, then
    /// `SessionRestoreReducer.restoredComponents` — rather than asserting on
    /// the snapshot alone, because an injection would live in the reducer.
    @Test("an empty tree survives a persistence round trip without gaining a group")
    func emptyTreeRoundTripsWithoutResurrectingAGroup() throws {
        let sole = SessionGroup(name: "sole", sessions: [])
        let store = SessionStore(groups: [sole])
        #expect(store.removeGroup(id: sole.id))
        #expect(store.groups.isEmpty, "premise: the tree must actually be empty to round trip")

        let snapshot = SessionSnapshot(groups: store.groups, selectedSessionID: nil)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try SessionSnapshot.decode(from: data)
        let restored = SessionRestoreReducer.restoredComponents(from: decoded)

        #expect(restored.groups.isEmpty, "restore must not conjure a default group")
    }

    @Test("closing an unknown group is a no-op")
    func closeUnknownGroupIsNoOp() {
        let session = makeSession("only")
        let group = SessionGroup(name: "group", sessions: [session])
        let store = SessionStore(groups: [group], selectedSessionID: session.id)

        store.closeGroup(id: SessionGroup.ID())

        #expect(store.groups.map(\.id) == [group.id])
        #expect(store.session(id: session.id) != nil)
    }

    @Test("closed workspaces are captured for reopen")
    func closedWorkspacesAreCapturedForReopen() {
        // User-edited titles make the sessions worth persisting — bare
        // shells only get the single transient slot, matching serial
        // per-workspace close semantics.
        let first = makeSession("first", isTitleUserEdited: true)
        let second = makeSession("second", isTitleUserEdited: true)
        let doomed = SessionGroup(name: "doomed", sessions: [first, second])
        let kept = SessionGroup(name: "kept", sessions: [makeSession("survivor")])
        let store = SessionStore(groups: [doomed, kept])

        store.closeGroup(id: doomed.id)

        #expect(store.canReopenClosedWorkspace)
        // Reopen the most recent close (the LAST session closed in the
        // loop) — its original group is gone, so the reducer recreates it.
        // Reopen mints a fresh session ID by design, so assert on title
        // and group shape rather than identity.
        let reopenedID = store.reopenMostRecentlyClosed()
        #expect(reopenedID != nil)
        let recreated = store.groups.first(where: { $0.name == "doomed" })
        #expect(recreated?.sessions.map(\.title) == ["second"])
        // A second reopen proves EVERY session in the group was captured,
        // not just the last one closed.
        #expect(store.reopenMostRecentlyClosed() != nil)
        let recreatedAgain = store.groups.first(where: { $0.name == "doomed" })
        #expect(recreatedAgain?.sessions.map(\.title).sorted() == ["first", "second"])
    }

    @Test("split-pane workspaces close through the single close path")
    func splitPaneWorkspaceClosesThroughSingleClosePath() {
        let split = makeSession("split")
        let doomed = SessionGroup(name: "doomed", sessions: [split])
        let kept = SessionGroup(name: "kept", sessions: [makeSession("survivor")])
        let store = SessionStore(groups: [doomed, kept], selectedSessionID: split.id)
        #expect(store.splitActivePane(orientation: .horizontal, in: split.id) != nil)
        #expect(store.session(id: split.id)?.layout.paneIDs.count == 2)

        store.closeGroup(id: doomed.id)

        #expect(store.session(id: split.id) == nil)
        #expect(store.groups.map(\.name) == ["kept"])
    }

    @Test("a session that joined after confirmation survives a limited close")
    func limitedCloseSparesUnconfirmedJoiner() {
        let first = makeSession("first")
        let second = makeSession("second")
        let doomed = SessionGroup(name: "doomed", sessions: [first, second])
        let kept = SessionGroup(name: "kept", sessions: [makeSession("survivor")])
        let store = SessionStore(groups: [doomed, kept])
        let confirmedIDs = [first.id, second.id]

        // Simulates a workspace joining the group while the confirm modal
        // is up: it was never part of the confirmed membership.
        _ = store.addSession(title: "joiner", groupName: "doomed")

        let removed = store.closeGroup(id: doomed.id, limitedTo: confirmedIDs)

        #expect(removed == false)
        #expect(store.session(id: first.id) == nil)
        #expect(store.session(id: second.id) == nil)
        let surviving = store.groups.first(where: { $0.id == doomed.id })
        #expect(surviving?.sessions.map(\.title) == ["joiner"])
    }

    @Test("a confirmed session that left the group survives a limited close")
    func limitedCloseSparesConfirmedLeaver() {
        let stays = makeSession("stays")
        let leaves = makeSession("leaves")
        let doomed = SessionGroup(name: "doomed", sessions: [stays, leaves])
        let other = SessionGroup(name: "other", sessions: [makeSession("survivor")])
        let store = SessionStore(groups: [doomed, other])
        let confirmedIDs = [stays.id, leaves.id]

        // Simulates a confirmed workspace being moved out of the group
        // while the confirm modal is up.
        store.moveSession(id: leaves.id, toGroupID: other.id, atIndex: SessionStore.appendIndex)

        let removed = store.closeGroup(id: doomed.id, limitedTo: confirmedIDs)

        #expect(removed == true)
        #expect(store.session(id: stays.id) == nil)
        #expect(store.session(id: leaves.id) != nil)
        let destination = store.groups.first(where: { $0.id == other.id })
        #expect(destination?.sessions.contains(where: { $0.id == leaves.id }) == true)
    }

    private func makeSession(
        _ title: String,
        agentState: AgentState = .idle,
        isTitleUserEdited: Bool = false
    ) -> TerminalSession {
        TerminalSession(
            title: title,
            workingDirectory: "~",
            isTitleUserEdited: isTitleUserEdited,
            agentKind: .shell,
            agentState: agentState
        )
    }
}
