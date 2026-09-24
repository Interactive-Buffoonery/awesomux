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

    // MARK: - Traversal runs (INT-819)

    @Test func traversalWalksEveryWorkspaceWhenAStickyReleasesMidRun() {
        let f = groups()
        // b starts lifted (needs input). Walking off it releases the sticky, so
        // the order collapses to plain group order on the very next press.
        let lifted = WorkspaceNavigationOrder.liftedFirstSessionIDs(
            in: f.groups,
            liftedSessionIDs: [f.b.id],
            pinnedSessionIDs: []
        )
        let afterRelease = WorkspaceNavigationOrder.liftedFirstSessionIDs(
            in: f.groups,
            pinnedSessionIDs: []
        )
        #expect(lifted == [f.b.id, f.a.id, f.c.id, f.d.id])
        #expect(afterRelease == [f.a.id, f.b.id, f.c.id, f.d.id])

        var selection = f.b.id
        var run: WorkspaceNavigationOrder.TraversalRun?
        var visited = [selection]
        // First press sees the lifted order; every later press sees the
        // released one — the reorder the run has to survive.
        for press in 0..<3 {
            guard
                let step = WorkspaceNavigationOrder.step(
                    offset: 1,
                    currentSelection: selection,
                    run: run,
                    freshOrder: press == 0 ? lifted : afterRelease
                )
            else {
                Issue.record("step returned nil mid-traversal")
                return
            }
            selection = step.selection
            run = step.run
            visited.append(selection)
        }
        // Without a pinned run this yields b, a, b, a — c and d never reached.
        #expect(visited == [f.b.id, f.a.id, f.c.id, f.d.id])
    }

    @Test func selectionFromAnotherPathInvalidatesTheRun() {
        let f = groups()
        let order = WorkspaceNavigationOrder.liftedFirstSessionIDs(
            in: f.groups,
            liftedSessionIDs: [f.d.id],
            pinnedSessionIDs: []
        )
        let first = WorkspaceNavigationOrder.step(
            offset: 1,
            currentSelection: f.d.id,
            run: nil,
            freshOrder: order
        )
        #expect(first?.selection == f.a.id)

        // A click/jump moved selection to c. The stale run must be ignored and
        // the fresh (no longer lifted) order used instead.
        let fresh = WorkspaceNavigationOrder.liftedFirstSessionIDs(
            in: f.groups,
            pinnedSessionIDs: []
        )
        let next = WorkspaceNavigationOrder.step(
            offset: 1,
            currentSelection: f.c.id,
            run: first?.run,
            freshOrder: fresh
        )
        #expect(next?.selection == f.d.id)
    }

    @Test func closingAnUnselectedWorkspaceMidRunNeverSelectsIt() {
        let f = groups()
        let order = WorkspaceNavigationOrder.liftedFirstSessionIDs(
            in: f.groups,
            pinnedSessionIDs: []
        )
        let first = WorkspaceNavigationOrder.step(
            offset: 1,
            currentSelection: f.a.id,
            run: nil,
            freshOrder: order
        )
        #expect(first?.selection == f.b.id)

        // c closes while b stays selected, so the run survives — but its
        // captured order still lists c.
        let afterClose = WorkspaceNavigationOrder.liftedFirstSessionIDs(
            in: [
                SessionGroup(name: "One", sessions: [f.a, f.b]),
                SessionGroup(name: "Two", sessions: [f.d]),
            ],
            pinnedSessionIDs: []
        )
        let next = WorkspaceNavigationOrder.step(
            offset: 1,
            currentSelection: f.b.id,
            run: first?.run,
            freshOrder: afterClose
        )
        #expect(next?.selection == f.d.id)
        #expect(next?.run?.order.contains(f.c.id) == false)
    }
}
