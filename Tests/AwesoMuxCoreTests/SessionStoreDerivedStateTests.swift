import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("SessionStore — Derived State (INT-376)")
struct SessionStoreDerivedStateTests {
    @Test("lookup and selection follow add, move, and close")
    func lookupAndSelectionFollowStructuralMutations() {
        let first = makeSession("first")
        let second = makeSession("second")
        let third = makeSession("third")
        let firstGroup = SessionGroup(name: "main", sessions: [first, second])
        let secondGroup = SessionGroup(name: "scratch", sessions: [third])
        let store = SessionStore(groups: [firstGroup, secondGroup], selectedSessionID: second.id)

        #expect(store.selectedSession?.id == second.id)
        #expect(store.session(id: second.id)?.title == "second")

        store.moveSession(id: second.id, toGroupID: secondGroup.id, atIndex: SessionStore.appendIndex)

        #expect(store.selectedSession?.id == second.id)
        #expect(store.session(id: second.id)?.title == "second")
        #expect(store.groups[1].sessions.map(\.id) == [third.id, second.id])

        store.closeSession(id: second.id)

        #expect(store.session(id: second.id) == nil)
        #expect(store.selectedSession?.id == third.id)
    }

    @Test("moving groups keeps indexed lookup and cycling order correct")
    func moveGroupKeepsLookupAndCyclingOrderCorrect() {
        let first = makeSession("first")
        let second = makeSession("second")
        let third = makeSession("third")
        let store = SessionStore(groups: [
            SessionGroup(name: "one", sessions: [first]),
            SessionGroup(name: "two", sessions: [second]),
            SessionGroup(name: "three", sessions: [third]),
        ], selectedSessionID: second.id)

        store.moveGroup(from: 2, to: 0)

        #expect(store.session(id: third.id)?.title == "third")
        #expect(store.selectedSession?.id == second.id)

        store.selectNextSession()

        #expect(store.selectedSession?.id == third.id)
    }

    @Test("selection offset preserves multi-step wraparound across groups")
    func selectionOffsetPreservesMultiStepWraparoundAcrossGroups() {
        let first = makeSession("first")
        let second = makeSession("second")
        let third = makeSession("third")
        let fourth = makeSession("fourth")
        let store = SessionStore(groups: [
            SessionGroup(name: "one", sessions: [first, second]),
            SessionGroup(name: "two", sessions: [third]),
            SessionGroup(name: "three", sessions: [fourth]),
        ], selectedSessionID: first.id)

        store.selectSession(offset: 2)
        #expect(store.selectedSession?.id == third.id)

        store.selectSession(offset: -3)
        #expect(store.selectedSession?.id == fourth.id)

        store.selectSession(offset: 5)
        #expect(store.selectedSession?.id == first.id)
    }

    @Test("replaceState(restoring:) rebuilds lookup and resets unread total")
    func replaceStateRestoringRebuildsLookupAndResetsUnreadTotal() {
        let original = makeSession("original", unreadNotificationCount: 2)
        let replacement = makeSession("replacement", unreadNotificationCount: 4)
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [original])
        ])
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "replacement", sessions: [replacement])],
            selectedSessionID: replacement.id
        )

        let summary = store.replaceState(restoring: snapshot)

        #expect(summary.isEmpty)
        #expect(store.session(id: original.id) == nil)
        #expect(store.session(id: replacement.id)?.title == "replacement")
        #expect(store.unreadNotificationTotal == 0)
    }

    @Test("restore rebuilds lookup and drops persisted unread badges")
    func restoreRebuildsDerivedState() {
        let first = makeSession("first", unreadNotificationCount: 2)
        let second = makeSession(
            "second",
            agentKind: .codex,
            agentState: .needsAttention,
            unreadNotificationCount: 3
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "main", sessions: [first, second])],
            selectedSessionID: second.id
        )

        let store = SessionStore(restoring: snapshot)

        #expect(store.selectedSession?.id == second.id)
        #expect(store.session(id: first.id)?.title == "first")
        #expect(store.session(id: second.id)?.title == "second")
        #expect(store.unreadNotificationTotal == 0)
    }

    @Test("unread total tracks public notification commands and acknowledgement")
    func unreadTotalTracksDeltasAndAcknowledgement() {
        let first = makeSession(
            "first",
            agentKind: .codex,
            agentState: .needsAttention,
            unreadNotificationCount: 2
        )
        let second = makeSession(
            "second",
            agentKind: .claudeCode,
            agentState: .needsAttention,
            unreadNotificationCount: 3
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [first, second])
        ])

        #expect(store.unreadNotificationTotal == 5)

        store.markSessionNeedsAttention(id: first.id, unreadNotificationDelta: 4)
        #expect(store.unreadNotificationTotal == 9)

        store.markSessionNeedsAttention(id: TerminalSession.ID(), unreadNotificationDelta: 10)
        #expect(store.unreadNotificationTotal == 9)

        store.acknowledgeSession(id: second.id)
        #expect(store.unreadNotificationTotal == 6)

        store.acknowledgeSession(id: first.id)
        #expect(store.unreadNotificationTotal == 0)

        store.markSessionNeedsAttention(id: first.id, unreadNotificationDelta: 2)
        store.acknowledgeSession(id: first.id)
        #expect(store.session(id: first.id)?.unreadNotificationCount == 0)
        #expect(store.unreadNotificationTotal == 0)

        store.markSessionNeedsAttention(id: first.id, unreadNotificationDelta: 2)
        store.markSessionNeedsAttention(id: second.id, unreadNotificationDelta: 3)
        store.acknowledgeAllSessions()
        #expect(store.unreadNotificationTotal == 0)
        #expect(store.session(id: first.id)?.unreadNotificationCount == 0)
        #expect(store.session(id: second.id)?.unreadNotificationCount == 0)
        #expect(store.session(id: first.id)?.agentState == .running)
        #expect(store.session(id: second.id)?.agentState == .running)
    }

    @Test("unread total tracks recycle, close, and reopen")
    func unreadTotalTracksRecycleCloseAndReopen() throws {
        let first = makeSession(
            "first",
            agentKind: .codex,
            agentState: .needsAttention,
            unreadNotificationCount: 2
        )
        let second = makeSession(
            "second",
            agentKind: .shell,
            agentState: .needsAttention,
            unreadNotificationCount: 4
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [first, second])
        ], selectedSessionID: first.id)

        #expect(store.unreadNotificationTotal == 6)

        store.recycleActivePane(in: first.id)
        #expect(store.unreadNotificationTotal == 4)

        store.closeSession(id: second.id)
        #expect(store.unreadNotificationTotal == 0)

        let reopenedID = try #require(store.reopenMostRecentlyClosed())
        #expect(store.session(id: reopenedID) != nil)
        #expect(store.selectedSession?.id == reopenedID)
        #expect(store.unreadNotificationTotal == 0)
    }

    @Test("duplicate session IDs count unread total only once and resolve to first occurrence")
    func duplicateSessionIDsDedupeUnreadTotalAndLookup() {
        let sharedID = TerminalSession.ID()
        let firstCopy = TerminalSession(
            id: sharedID,
            title: "first",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle,
            unreadNotificationCount: 3
        )
        let secondCopy = TerminalSession(
            id: sharedID,
            title: "second",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle,
            unreadNotificationCount: 7
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "one", sessions: [firstCopy]),
            SessionGroup(name: "two", sessions: [secondCopy]),
        ])

        // Only the first occurrence contributes — the second copy's 7 must
        // not be added on top of the first copy's 3.
        #expect(store.unreadNotificationTotal == 3)
        #expect(store.session(id: sharedID)?.title == "first")
    }

    @Test("replaceState(restoring:) falls back when snapshot selection is stale")
    func replaceStateRestoringFallsBackWhenSnapshotSelectionIsStale() {
        let first = makeSession("first")
        let second = makeSession("second")
        let replacement = makeSession("replacement")
        let store = SessionStore(
            groups: [SessionGroup(name: "main", sessions: [first, second])],
            selectedSessionID: second.id
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "next", sessions: [replacement])],
            selectedSessionID: second.id
        )

        let summary = store.replaceState(restoring: snapshot)

        #expect(summary.selectedSessionFallbacks == 1)
        #expect(store.session(id: second.id) == nil)
        #expect(store.selectedSessionID == replacement.id)
    }

    @Test("offset cycling skips empty middle groups")
    func offsetCyclingSkipsEmptyMiddleGroups() {
        let first = makeSession("first")
        let second = makeSession("second")
        let store = SessionStore(groups: [
            SessionGroup(name: "one", sessions: [first]),
            SessionGroup(name: "empty", sessions: []),
            SessionGroup(name: "two", sessions: [second]),
        ], selectedSessionID: first.id)

        store.selectSession(offset: 1)
        #expect(store.selectedSession?.id == second.id)

        store.selectSession(offset: -1)
        #expect(store.selectedSession?.id == first.id)
    }

    @Test("offset cycling stays put with a single session")
    func offsetCyclingStaysPutWithSingleSession() {
        let only = makeSession("only")
        let store = SessionStore(
            groups: [SessionGroup(name: "main", sessions: [only])],
            selectedSessionID: only.id
        )

        store.selectSession(offset: 1)
        #expect(store.selectedSession?.id == only.id)

        store.selectSession(offset: -1)
        #expect(store.selectedSession?.id == only.id)
    }

    private func makeSession(
        _ title: String,
        agentKind: AgentKind = .shell,
        agentState: AgentState = .idle,
        unreadNotificationCount: Int = 0
    ) -> TerminalSession {
        TerminalSession(
            title: title,
            workingDirectory: "~",
            agentKind: agentKind,
            agentState: agentState,
            unreadNotificationCount: unreadNotificationCount
        )
    }
}
