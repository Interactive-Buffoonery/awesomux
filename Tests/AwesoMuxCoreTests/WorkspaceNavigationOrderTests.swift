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
        let order = WorkspaceNavigationOrder.liftedFirstSessionIDs(
            in: f.groups,
            pinnedSessionIDs: []
        )
        #expect(order == [f.a.id, f.b.id, f.c.id, f.d.id])
    }

    @Test func pinnedComeFirstInPinOrderThenGroupOrder() {
        let f = groups()
        // Pin c then a — pin order, NOT group order.
        let order = WorkspaceNavigationOrder.liftedFirstSessionIDs(
            in: f.groups,
            pinnedSessionIDs: [f.c.id, f.a.id]
        )
        #expect(order == [f.c.id, f.a.id, f.b.id, f.d.id])
    }

    @Test func staleAndMissingPinnedIDsAreDropped() {
        let f = groups()
        let ghost = TerminalSession(title: "ghost", workingDirectory: "~").id
        let order = WorkspaceNavigationOrder.liftedFirstSessionIDs(
            in: f.groups,
            pinnedSessionIDs: [ghost, f.b.id]
        )
        // ghost isn't a live session, so it's dropped; b floats first.
        #expect(order == [f.b.id, f.a.id, f.c.id, f.d.id])
    }

    @Test func liftedComeBeforePinnedAndTheRest() {
        let a = TerminalSession(title: "alpha", workingDirectory: "~")
        let b = TerminalSession(title: "beta", workingDirectory: "~")
        let c = TerminalSession(title: "gamma", workingDirectory: "~")
        let g = SessionGroup(name: "One", sessions: [a, b, c])
        let order = WorkspaceNavigationOrder.liftedFirstSessionIDs(
            in: [g],
            liftedSessionIDs: [c.id],
            pinnedSessionIDs: [b.id]
        )
        #expect(order == [c.id, b.id, a.id])
    }

    @Test func aSessionNeverAppearsTwice() {
        // Pinned wins, so a pinned id passed as lifted must not duplicate.
        let a = TerminalSession(title: "alpha", workingDirectory: "~")
        let g = SessionGroup(name: "One", sessions: [a])
        let order = WorkspaceNavigationOrder.liftedFirstSessionIDs(
            in: [g],
            liftedSessionIDs: [a.id],
            pinnedSessionIDs: [a.id]
        )
        #expect(order == [a.id])
    }

    @Test func staleLiftedIDsAreDropped() {
        let a = TerminalSession(title: "alpha", workingDirectory: "~")
        let g = SessionGroup(name: "One", sessions: [a])
        let order = WorkspaceNavigationOrder.liftedFirstSessionIDs(
            in: [g],
            liftedSessionIDs: [UUID()],
            pinnedSessionIDs: []
        )
        #expect(order == [a.id])
    }

    @Test func pinnedWinsTheTieNotLifted() {
        // aSessionNeverAppearsTwice only proves dedup happens, not which list
        // wins: a single shared id gives [a.id] either way. Here lifted and
        // pinned disagree on ORDER (a is lifted, b is pinned-only, but a is
        // ALSO pinned) so pinned-wins ([b.id, a.id]) and a hypothetical
        // lifted-wins ([a.id, b.id]) diverge in output.
        let a = TerminalSession(title: "alpha", workingDirectory: "~")
        let b = TerminalSession(title: "beta", workingDirectory: "~")
        let g = SessionGroup(name: "One", sessions: [a, b])
        let order = WorkspaceNavigationOrder.liftedFirstSessionIDs(
            in: [g],
            liftedSessionIDs: [a.id],
            pinnedSessionIDs: [b.id, a.id]
        )
        #expect(order == [b.id, a.id])
    }
}
