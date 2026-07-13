import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("PaneLayoutReducer move and swap")
struct PaneLayoutReducerMoveTests {
    // MARK: - Fixtures

    /// Side-by-side `L | R` layout (`.vertical` => first is LEFT, second is RIGHT).
    private func makeSideBySideSession(
        active: (TerminalPane, TerminalPane) -> TerminalPane
    ) -> (session: TerminalSession, left: TerminalPane, right: TerminalPane) {
        let left = TerminalPane(title: "left", workingDirectory: "/l", executionPlan: .local)
        let right = TerminalPane(title: "right", workingDirectory: "/r", executionPlan: .local)
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(left),
            second: .pane(right),
            firstFraction: 0.35
        ))
        let activePane = active(left, right)
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: activePane.workingDirectory,
            agentKind: .shell,
            layout: layout,
            activePaneID: activePane.id
        )
        return (session, left, right)
    }

    /// Depth-first order [a, b, c]: a|b nested vertical, stacked over c.
    private func makeThreePaneSession(
        active: (TerminalPane, TerminalPane, TerminalPane) -> TerminalPane
    ) -> (session: TerminalSession, panes: (TerminalPane, TerminalPane, TerminalPane)) {
        let a = TerminalPane(title: "a", workingDirectory: "/a", executionPlan: .local)
        let b = TerminalPane(title: "b", workingDirectory: "/b", executionPlan: .local)
        let c = TerminalPane(title: "c", workingDirectory: "/c", executionPlan: .local)
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .horizontal,
            first: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(a),
                second: .pane(b),
                firstFraction: 0.4
            )),
            second: .pane(c),
            firstFraction: 0.6
        ))
        let activePane = active(a, b, c)
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: activePane.workingDirectory,
            agentKind: .shell,
            layout: layout,
            activePaneID: activePane.id
        )
        return (session, (a, b, c))
    }

    // MARK: - Workspace-edge moves

    @Test("L | R: moving left pane to top edge yields a stacked layout with it first")
    func moveLeftPaneToTopEdge() throws {
        let (session, left, right) = makeSideBySideSession { left, _ in left }

        let updated = try #require(PaneLayoutReducer.movePane(
            id: left.id,
            toWorkspaceEdge: .up,
            in: session
        ))

        guard case let .split(root) = updated.layout else {
            Issue.record("Expected a root split")
            return
        }
        #expect(root.orientation == .horizontal) // stacked
        #expect(root.first == .pane(left))       // moved pane on top
        #expect(root.second == .pane(right))     // remainder below
        #expect(updated.layout.paneIDs == [left.id, right.id])
    }

    @Test("moving a pane to the right edge places it as the second slot")
    func moveToRightEdgePlacesSecond() throws {
        let (session, panes) = makeThreePaneSession { a, _, _ in a }
        let updated = try #require(PaneLayoutReducer.movePane(
            id: panes.2.id,
            toWorkspaceEdge: .right,
            in: session
        ))
        guard case let .split(root) = updated.layout else {
            Issue.record("Expected a root split")
            return
        }
        #expect(root.orientation == .vertical)   // side-by-side
        #expect(root.second == .pane(panes.2))   // moved pane on the right
    }

    @Test("workspace-edge move uses a 0.5 fraction on the new root split")
    func workspaceEdgeMoveUsesHalfFraction() throws {
        let (session, left, _) = makeSideBySideSession { left, _ in left }
        let updated = try #require(PaneLayoutReducer.movePane(
            id: left.id,
            toWorkspaceEdge: .down,
            in: session
        ))
        guard case let .split(root) = updated.layout else {
            Issue.record("Expected a root split")
            return
        }
        #expect(root.firstFraction == 0.5)
    }

    @Test("no-op: moving the sole-left pane to the left workspace edge is rejected")
    func moveLeftPaneToLeftEdgeIsNoOp() {
        let (session, left, _) = makeSideBySideSession { left, _ in left }
        #expect(PaneLayoutReducer.movePane(
            id: left.id,
            toWorkspaceEdge: .left,
            in: session
        ) == nil)
    }

    @Test("no-op: moving the sole-right pane to the right workspace edge is rejected")
    func moveRightPaneToRightEdgeIsNoOp() {
        let (session, _, right) = makeSideBySideSession { _, right in right }
        #expect(PaneLayoutReducer.movePane(
            id: right.id,
            toWorkspaceEdge: .right,
            in: session
        ) == nil)
    }

    @Test("single-pane layout rejects every workspace-edge move")
    func singlePaneRejectsWorkspaceEdgeMove() {
        let pane = TerminalPane(title: "only", workingDirectory: "~", executionPlan: .local)
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: "~",
            agentKind: .shell,
            layout: .pane(pane),
            activePaneID: pane.id
        )
        for edge in [PaneMoveEdge.up, .down, .left, .right] {
            #expect(PaneLayoutReducer.movePane(id: pane.id, toWorkspaceEdge: edge, in: session) == nil)
        }
    }

    @Test("unknown pane id rejects a workspace-edge move")
    func unknownPaneRejectsWorkspaceEdgeMove() {
        let (session, _, _) = makeSideBySideSession { left, _ in left }
        #expect(PaneLayoutReducer.movePane(
            id: UUID(),
            toWorkspaceEdge: .up,
            in: session
        ) == nil)
    }

    // MARK: - Adjacent-pane moves

    @Test("adjacent move splits the target in place and reparents both panes")
    func adjacentMoveSplitsTarget() throws {
        let (session, panes) = makeThreePaneSession { a, _, _ in a }
        // Move `a` adjacent to `c` on the down edge -> c stacked over a.
        let updated = try #require(PaneLayoutReducer.movePane(
            id: panes.0.id,
            adjacentToPane: panes.2.id,
            onEdge: .down,
            in: session
        ))

        // Same pane set, no losses/dupes.
        #expect(Set(updated.layout.paneIDs) == Set([panes.0.id, panes.1.id, panes.2.id]))
        #expect(updated.layout.paneIDs.count == 3)
        // c now lives in a vertical/horizontal split with a underneath.
        let split = try #require(findSplit(in: updated.layout) { s in
            s.first.contains(paneID: panes.2.id) && s.second.contains(paneID: panes.0.id)
        })
        #expect(split.orientation == .horizontal)
        #expect(split.first == TerminalPaneLayout.pane(panes.2))  // target on top
        #expect(split.second == TerminalPaneLayout.pane(panes.0)) // moved pane below
    }

    @Test("sibling adjacent move: removal collapses the shared split, target relocated")
    func siblingAdjacentMove() throws {
        // a and b are siblings in the inner vertical split. Move a adjacent to b.
        let (session, panes) = makeThreePaneSession { _, b, _ in b }
        let updated = try #require(PaneLayoutReducer.movePane(
            id: panes.0.id,
            adjacentToPane: panes.1.id,
            onEdge: .up,
            in: session
        ))
        #expect(Set(updated.layout.paneIDs) == Set([panes.0.id, panes.1.id, panes.2.id]))
        let split = try #require(findSplit(in: updated.layout) { s in
            s.first.contains(paneID: panes.0.id) && s.second.contains(paneID: panes.1.id)
        })
        #expect(split.orientation == .horizontal)
        #expect(split.first == TerminalPaneLayout.pane(panes.0)) // moved pane on top
        #expect(split.second == TerminalPaneLayout.pane(panes.1))
    }

    @Test("adjacent move onto self is rejected")
    func adjacentMoveOntoSelfRejected() {
        let (session, panes) = makeThreePaneSession { a, _, _ in a }
        #expect(PaneLayoutReducer.movePane(
            id: panes.0.id,
            adjacentToPane: panes.0.id,
            onEdge: .left,
            in: session
        ) == nil)
    }

    @Test("adjacent move with unknown target is rejected")
    func adjacentMoveUnknownTargetRejected() {
        let (session, panes) = makeThreePaneSession { a, _, _ in a }
        #expect(PaneLayoutReducer.movePane(
            id: panes.0.id,
            adjacentToPane: UUID(),
            onEdge: .left,
            in: session
        ) == nil)
    }

    @Test("adjacent move in a single-pane layout is rejected")
    func adjacentMoveSinglePaneRejected() {
        let pane = TerminalPane(title: "only", workingDirectory: "~", executionPlan: .local)
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: "~",
            agentKind: .shell,
            layout: .pane(pane),
            activePaneID: pane.id
        )
        #expect(PaneLayoutReducer.movePane(
            id: pane.id,
            adjacentToPane: pane.id,
            onEdge: .left,
            in: session
        ) == nil)
    }

    @Test("adjacent move that reproduces the current layout is rejected as a no-op")
    func adjacentMoveNoOpRejected() {
        // L | R, move R adjacent to L on the right edge -> identical L | R.
        let (session, left, right) = makeSideBySideSession { left, _ in left }
        #expect(PaneLayoutReducer.movePane(
            id: right.id,
            adjacentToPane: left.id,
            onEdge: .right,
            in: session
        ) == nil)
    }

    // MARK: - Swap

    @Test("swap exchanges two panes while preserving shape and fractions")
    func swapPreservesShape() throws {
        let (session, panes) = makeThreePaneSession { a, _, _ in a }
        let before = session.layout
        let updated = try #require(PaneLayoutReducer.swapPanes(
            firstID: panes.0.id,
            secondID: panes.2.id,
            in: session
        ))

        // Same pane set, same ordering count.
        #expect(Set(updated.layout.paneIDs) == Set([panes.0.id, panes.1.id, panes.2.id]))
        // Fractions on every split survive (shape unchanged, only panes relocate).
        #expect(splitFractions(updated.layout) == splitFractions(before))
        // a now sits where c was (second slot of root) and vice versa.
        guard case let .split(root) = updated.layout else {
            Issue.record("Expected a root split")
            return
        }
        #expect(root.second == TerminalPaneLayout.pane(panes.0)) // a moved to c's old slot
        let innerSplit = try #require(findSplit(in: updated.layout) { $0.orientation == .vertical })
        #expect(innerSplit.first == TerminalPaneLayout.pane(panes.2)) // c moved to a's old slot
    }

    @Test("swap rejects self-swap and unknown ids")
    func swapRejectsInvalid() {
        let (session, panes) = makeThreePaneSession { a, _, _ in a }
        #expect(PaneLayoutReducer.swapPanes(firstID: panes.0.id, secondID: panes.0.id, in: session) == nil)
        #expect(PaneLayoutReducer.swapPanes(firstID: panes.0.id, secondID: UUID(), in: session) == nil)
        #expect(PaneLayoutReducer.swapPanes(firstID: UUID(), secondID: panes.1.id, in: session) == nil)
    }

    @Test("swap makes the first pane active and syncs chrome")
    func swapFocusesFirstPane() throws {
        let (session, panes) = makeThreePaneSession { _, b, _ in b }
        let updated = try #require(PaneLayoutReducer.swapPanes(
            firstID: panes.0.id,
            secondID: panes.2.id,
            in: session
        ))
        #expect(updated.activePaneID == panes.0.id)
        #expect(updated.workingDirectory == "/a")
        #expect(updated.title == "a")
    }

    // MARK: - Identity and focus invariants

    @Test("pane identity is preserved (reparenting, not recreation)")
    func paneIdentityPreserved() throws {
        let (session, left, _) = makeSideBySideSession { left, _ in left }
        let updated = try #require(PaneLayoutReducer.movePane(
            id: left.id,
            toWorkspaceEdge: .down,
            in: session
        ))
        let moved = try #require(updated.layout.pane(id: left.id))
        // Full value equality, not just id — title/cwd/host all intact.
        #expect(moved == left)
        #expect(moved.title == left.title)
        #expect(moved.workingDirectory == left.workingDirectory)
    }

    @Test("focus follows the moved pane and syncs chrome")
    func focusFollowsMovedPane() throws {
        let (session, left, _) = makeSideBySideSession { _, right in right }
        // active is `right`; moving `left` should pull focus onto `left`.
        let updated = try #require(PaneLayoutReducer.movePane(
            id: left.id,
            toWorkspaceEdge: .up,
            in: session
        ))
        #expect(updated.activePaneID == left.id)
        #expect(updated.workingDirectory == "/l")
        #expect(updated.title == "left")
    }

    @Test("moving the active pane keeps it active")
    func movingActivePaneKeepsItActive() throws {
        let (session, left, _) = makeSideBySideSession { left, _ in left }
        let updated = try #require(PaneLayoutReducer.movePane(
            id: left.id,
            toWorkspaceEdge: .up,
            in: session
        ))
        #expect(updated.activePaneID == left.id)
    }

    // MARK: - Deep nesting and persistence

    @Test("deep nesting round-trips: move then move back restores the pane set")
    func deepNestingRoundTrips() throws {
        let (session, panes) = makeThreePaneSession { a, _, _ in a }
        let moved = try #require(PaneLayoutReducer.movePane(
            id: panes.1.id,
            toWorkspaceEdge: .right,
            in: session
        ))
        #expect(Set(moved.layout.paneIDs) == Set([panes.0.id, panes.1.id, panes.2.id]))

        let movedBack = try #require(PaneLayoutReducer.movePane(
            id: panes.1.id,
            adjacentToPane: panes.0.id,
            onEdge: .right,
            in: moved
        ))
        #expect(Set(movedBack.layout.paneIDs) == Set([panes.0.id, panes.1.id, panes.2.id]))
        #expect(movedBack.layout.paneIDs.count == 3)
    }

    @Test("post-move layout survives a Codable round-trip")
    func postMoveCodableRoundTrip() throws {
        let (session, panes) = makeThreePaneSession { a, _, _ in a }
        let updated = try #require(PaneLayoutReducer.movePane(
            id: panes.0.id,
            adjacentToPane: panes.2.id,
            onEdge: .down,
            in: session
        ))

        let data = try JSONEncoder().encode(updated.layout)
        let decoded = try JSONDecoder().decode(TerminalPaneLayout.self, from: data)
        #expect(decoded == updated.layout)
    }

    @Test("paneIDs depth-first ordering stays coherent after a move (no dupes, no losses)")
    func paneIDsCoherentAfterMove() throws {
        let (session, panes) = makeThreePaneSession { a, _, _ in a }
        let updated = try #require(PaneLayoutReducer.movePane(
            id: panes.2.id,
            adjacentToPane: panes.1.id,
            onEdge: .up,
            in: session
        ))
        let ids = updated.layout.paneIDs
        #expect(ids.count == Set(ids).count) // no duplicates
        #expect(Set(ids) == Set([panes.0.id, panes.1.id, panes.2.id])) // same set
    }

    @Test("untouched splits keep their firstFraction")
    func untouchedSplitsKeepFraction() throws {
        let (session, panes) = makeThreePaneSession { a, _, _ in a }
        // Inner a|b split has firstFraction 0.4; move c adjacent to a, which
        // rewrites a's subtree but the inner a|b split should be untouched.
        let updated = try #require(PaneLayoutReducer.movePane(
            id: panes.2.id,
            adjacentToPane: panes.0.id,
            onEdge: .left,
            in: session
        ))
        // b is still split against a's neighbor at 0.4.
        let abSplit = try #require(findSplit(in: updated.layout) { s in
            (s.first.contains(paneID: panes.1.id) || s.second.contains(paneID: panes.1.id))
                && s.firstFraction == 0.4
        })
        #expect(abSplit.firstFraction == 0.4)
    }

    // MARK: - can* predicates

    @Test("canMovePane mirrors movePane validity")
    func canMoveMirrorsMove() {
        let (session, left, _) = makeSideBySideSession { left, _ in left }
        #expect(PaneLayoutReducer.canMovePane(id: left.id, toWorkspaceEdge: .up, in: session))
        #expect(!PaneLayoutReducer.canMovePane(id: left.id, toWorkspaceEdge: .left, in: session))
    }

    @Test("canSwapPanes mirrors swapPanes validity")
    func canSwapMirrorsSwap() {
        let (session, panes) = makeThreePaneSession { a, _, _ in a }
        #expect(PaneLayoutReducer.canSwapPanes(firstID: panes.0.id, secondID: panes.2.id, in: session))
        #expect(!PaneLayoutReducer.canSwapPanes(firstID: panes.0.id, secondID: panes.0.id, in: session))
    }

    // MARK: - Helpers

    private func findSplit(
        in layout: TerminalPaneLayout,
        where predicate: (TerminalSplit) -> Bool
    ) -> TerminalSplit? {
        switch layout {
        case .pane:
            return nil
        case let .split(split):
            if predicate(split) {
                return split
            }
            return findSplit(in: split.first, where: predicate)
                ?? findSplit(in: split.second, where: predicate)
        case .documentGroup:
            return nil
        }
    }

    private func splitFractions(_ layout: TerminalPaneLayout) -> [Double] {
        switch layout {
        case .pane:
            return []
        case let .split(split):
            return [split.firstFraction]
                + splitFractions(split.first)
                + splitFractions(split.second)
        case .documentGroup:
            return []
        }
    }
}
