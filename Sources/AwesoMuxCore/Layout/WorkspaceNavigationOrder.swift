import Foundation

/// Lifted-first flattened session order — the sidebar's visual order when no
/// filter is active. Jump digits, Previous/Next Workspace, the Dock menu, and
/// the sidebar badges must all resolve from THIS order or ⌘-digit labels lie
/// (INT-737 plan review). Lives in the app-facing core (not on the `internal`
/// `WorkspaceTreeReducer`) so the SidebarView label map and the app's
/// jump/prev/next actions share one definition.
public enum WorkspaceNavigationOrder {
    /// Needs Input first, then pinned in pin order, then the remaining sessions
    /// in group order. Stale IDs (no live session) are dropped so the order
    /// can't index past the roster. Pinned wins: an ID in both lists is emitted
    /// once, in the pinned block.
    public static func liftedFirstSessionIDs(
        in groups: [SessionGroup],
        liftedSessionIDs: [TerminalSession.ID] = [],
        pinnedSessionIDs: [TerminalSession.ID]
    ) -> [TerminalSession.ID] {
        let orderedIDs = groups.flatMap(\.sessions).map(\.id)
        let liveIDs = Set(orderedIDs)
        let pinned = pinnedSessionIDs.filter { liveIDs.contains($0) }
        let pinnedSet = Set(pinned)
        let lifted = liftedSessionIDs.filter { liveIDs.contains($0) && !pinnedSet.contains($0) }
        let liftedSet = Set(lifted)
        let remaining = orderedIDs.filter { !pinnedSet.contains($0) && !liftedSet.contains($0) }
        return lifted + pinned + remaining
    }

    /// A run of consecutive Previous/Next Workspace presses.
    ///
    /// Selecting a workspace can release another's attention sticky, which drops
    /// that row out of Needs Input and reorders the very list the walk came
    /// from. Re-deriving the position from the mutated order on the next press
    /// skips a workspace and revisits one already seen (`A → B → A`), so a run
    /// keeps walking the order captured at its first press (INT-819).
    public struct TraversalRun: Equatable, Sendable {
        public var order: [TerminalSession.ID]
        /// The selection this run last produced. Anything else means selection
        /// moved by some other path (a click, a jump digit, a close) and the
        /// captured order is stale.
        public var selection: TerminalSession.ID

        public init(order: [TerminalSession.ID], selection: TerminalSession.ID) {
            self.order = order
            self.selection = selection
        }
    }

    /// Resolves one Previous/Next step. Returns the next selection and the run
    /// to carry into the following press, or `nil` when there is nothing to
    /// select. Pass the previous call's `run` back in to continue a traversal;
    /// pass `nil` to start a fresh one.
    public static func step(
        offset: Int,
        currentSelection: TerminalSession.ID?,
        run: TraversalRun?,
        freshOrder: @autoclosure () -> [TerminalSession.ID]
    ) -> (selection: TerminalSession.ID, run: TraversalRun?)? {
        let order: [TerminalSession.ID]
        if let run, run.selection == currentSelection {
            order = run.order
        } else {
            order = freshOrder()
        }
        guard order.count > 1 else {
            return order.first.map { ($0, nil) }
        }
        guard let currentSelection,
            let currentIndex = order.firstIndex(of: currentSelection)
        else {
            return order.first.map { ($0, nil) }
        }
        let count = order.count
        let next = order[((currentIndex + offset) % count + count) % count]
        return (next, TraversalRun(order: order, selection: next))
    }
}
