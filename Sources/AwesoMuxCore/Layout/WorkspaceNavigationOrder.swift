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
}
