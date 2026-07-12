import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite struct SessionStorePinnedTests {
    private func makeStore() -> (store: SessionStore, a: TerminalSession, b: TerminalSession, c: TerminalSession) {
        let a = TerminalSession(title: "alpha", workingDirectory: "~")
        let b = TerminalSession(title: "beta", workingDirectory: "~")
        let c = TerminalSession(title: "gamma", workingDirectory: "~")
        let store = SessionStore(groups: [
            SessionGroup(name: "One", sessions: [a, b]),
            SessionGroup(name: "Two", sessions: [c])
        ])
        return (store, a, b, c)
    }

    @Test func togglePinAppendsInPinOrder() {
        let (store, a, _, c) = makeStore()
        store.togglePin(sessionID: c.id)
        store.togglePin(sessionID: a.id)
        #expect(store.pinnedSessionIDs == [c.id, a.id])
        #expect(store.isPinned(a.id))
        #expect(!store.isPinned(store.groups[0].sessions[1].id))
    }

    @Test func togglePinTwiceUnpins() {
        let (store, a, _, _) = makeStore()
        store.togglePin(sessionID: a.id)
        store.togglePin(sessionID: a.id)
        #expect(store.pinnedSessionIDs.isEmpty)
    }

    @Test func togglePinUnknownSessionIsNoOp() {
        let (store, _, _, _) = makeStore()
        store.togglePin(sessionID: UUID())
        #expect(store.pinnedSessionIDs.isEmpty)
    }

    @Test func movePinnedSessionReorders() {
        let (store, a, b, c) = makeStore()
        for id in [a.id, b.id, c.id] { store.togglePin(sessionID: id) }
        store.movePinnedSession(fromIndex: 2, toIndex: 0)
        #expect(store.pinnedSessionIDs == [c.id, a.id, b.id])
    }

    @Test func movePinnedSessionDownwardUsesFinalIndex() {
        let (store, a, b, c) = makeStore()
        for id in [a.id, b.id, c.id] { store.togglePin(sessionID: id) }
        store.movePinnedSession(fromIndex: 0, toIndex: 2)
        #expect(store.pinnedSessionIDs == [b.id, c.id, a.id])
    }

    @Test func movePinnedSessionOutOfBoundsIsNoOp() {
        let (store, a, _, _) = makeStore()
        store.togglePin(sessionID: a.id)
        store.movePinnedSession(fromIndex: 5, toIndex: 0)
        store.movePinnedSession(fromIndex: 0, toIndex: -1)
        #expect(store.pinnedSessionIDs == [a.id])
    }

    @Test func closingSessionPrunesPin() {
        let (store, a, _, _) = makeStore()
        store.togglePin(sessionID: a.id)
        store.closeSession(id: a.id)
        #expect(store.pinnedSessionIDs.isEmpty)
    }

    @Test func removingGroupPrunesItsPinnedSessions() {
        let (store, _, _, c) = makeStore()
        store.togglePin(sessionID: c.id)
        store.closeGroup(id: store.groups[1].id)
        #expect(store.pinnedSessionIDs.isEmpty)
    }
}
