import Foundation

/// Pinned-first flattened session order — the sidebar's visual order when
/// no filter is active. Jump digits, Previous/Next Workspace, and the
/// sidebar badges must all resolve from THIS order or ⌘-digit labels lie
/// (INT-737 plan review). Lives in the app-facing core (not on the
/// `internal` `WorkspaceTreeReducer`) so both the SidebarView label map and
/// the app's jump/prev/next actions can share one definition.
public enum WorkspaceNavigationOrder {
    /// Pinned IDs that resolve to live sessions first, in pin order; then the
    /// remaining sessions in group order. Stale pins (IDs with no live
    /// session) are dropped so the order can't index past the roster.
    public static func pinnedFirstSessionIDs(
        in groups: [SessionGroup],
        pinnedSessionIDs: [TerminalSession.ID]
    ) -> [TerminalSession.ID] {
        let orderedIDs = groups.flatMap(\.sessions).map(\.id)
        let liveIDs = Set(orderedIDs)
        let pinned = pinnedSessionIDs.filter { liveIDs.contains($0) }
        let pinnedSet = Set(pinned)
        let remaining = orderedIDs.filter { !pinnedSet.contains($0) }
        return pinned + remaining
    }
}
