import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct WorkspaceNavigationOrderTests {
    private func groups() -> (groups: [SessionGroup], a: TerminalSession, b: TerminalSession, c: TerminalSession, d: TerminalSession) {
        let a = TerminalSession(title: "a", workingDirectory: "~")
        let b = TerminalSession(title: "b", workingDirectory: "~")
        let c = TerminalSession(title: "c", workingDirectory: "~")
        let d = TerminalSession(title: "d", workingDirectory: "~")
        let groups = [
            SessionGroup(name: "One", sessions: [a, b]),
            SessionGroup(name: "Two", sessions: [c, d])
        ]
        return (groups, a, b, c, d)
    }

    @Test func noPinnedPreservesGroupOrder() {
        let f = groups()
        let order = WorkspaceNavigationOrder.pinnedFirstSessionIDs(
            in: f.groups,
            pinnedSessionIDs: []
        )
        #expect(order == [f.a.id, f.b.id, f.c.id, f.d.id])
    }

    @Test func pinnedComeFirstInPinOrderThenGroupOrder() {
        let f = groups()
        // Pin c then a — pin order, NOT group order.
        let order = WorkspaceNavigationOrder.pinnedFirstSessionIDs(
            in: f.groups,
            pinnedSessionIDs: [f.c.id, f.a.id]
        )
        #expect(order == [f.c.id, f.a.id, f.b.id, f.d.id])
    }

    @Test func staleAndMissingPinnedIDsAreDropped() {
        let f = groups()
        let ghost = TerminalSession(title: "ghost", workingDirectory: "~").id
        let order = WorkspaceNavigationOrder.pinnedFirstSessionIDs(
            in: f.groups,
            pinnedSessionIDs: [ghost, f.b.id]
        )
        // ghost isn't a live session, so it's dropped; b floats first.
        #expect(order == [f.b.id, f.a.id, f.c.id, f.d.id])
    }
}
