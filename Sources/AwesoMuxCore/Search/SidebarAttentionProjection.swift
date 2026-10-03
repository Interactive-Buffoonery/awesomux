import Foundation

/// Post-pinned projection that lifts workspaces awaiting a human answer into the
/// sidebar's synthetic Needs Input section and hides them inside their origin
/// groups. Nothing moves in the store — acknowledging a workspace drops its ID
/// from `SessionStore.liftedSessionIDs` and the row re-renders at its unchanged
/// index in its group, exactly like unpinning.
///
/// Structurally parallel to `SidebarPinnedProjection`: both CONSUME an ordered
/// ID list the store maintains rather than recomputing membership, which is what
/// makes the rendered order and `WorkspaceNavigationOrder.liftedFirstSessionIDs`
/// agree by construction instead of by two implementations happening to match.
///
/// Chained AFTER `SidebarPinnedProjection` over its reduced `entries`, so a
/// pinned workspace is already gone from the input and can never be lifted
/// twice: pinned wins by construction, with no precedence check.
public enum SidebarAttentionProjection {
    /// The single definition of membership, applied by
    /// `SessionStore.reconcileLiftedSessionIDs()`. Lives here, next to the
    /// projection it feeds, so the rule and its only renderer stay together.
    ///
    /// Deliberately blind to the selection: the sticky ID is written in reaction
    /// to a selection change, so any render pass can observe a new selection
    /// against a not-yet-updated sticky. Excluding the selected session here
    /// would demote a just-clicked row for one pass and lift it back the next.
    /// - Parameter unansweredTurnPaneIDs: `SessionStore.unansweredTurnPaneIDs` —
    ///   panes whose finished turn the agent reported as unanswered. A second
    ///   membership source rather than a second attention reason, because a
    ///   reason would also repaint the tile peach, open the notification
    ///   channel, and make the pane unreceptive to the document nudge. Lifting
    ///   is the only effect wanted here.
    public static func isLifted(
        _ session: TerminalSession,
        stickySessionID: TerminalSession.ID?,
        unansweredTurnPaneIDs: Set<TerminalPane.ID> = []
    ) -> Bool {
        session.id == stickySessionID
            || session.needsUserInput
            || session.hasUnansweredTurn(in: unansweredTurnPaneIDs)
    }

    public struct Output: Equatable, Sendable {
        public let attention: [LiftedSessionEntry]
        public let entries: [SidebarGroupEntry]
        public let topMatch: TerminalSession.ID?

        public init(
            attention: [LiftedSessionEntry],
            entries: [SidebarGroupEntry],
            topMatch: TerminalSession.ID?
        ) {
            self.attention = attention
            self.entries = entries
            self.topMatch = topMatch
        }
    }

    public static func apply(
        entries: [SidebarGroupEntry],
        liftedSessionIDs: [TerminalSession.ID],
        isFiltering: Bool,
        searchTopMatch: TerminalSession.ID?
    ) -> Output {
        let partition = SidebarLiftedPartition.apply(
            entries: entries,
            orderedSessionIDs: liftedSessionIDs,
            isFiltering: isFiltering,
            searchTopMatch: searchTopMatch
        )
        return Output(attention: partition.lifted, entries: partition.entries, topMatch: partition.topMatch)
    }
}
