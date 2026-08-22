import AwesoMuxCore

/// Classifies a change to `SessionStore.liftedSessionIDs` for the sidebar's
/// Needs Input side effects (auto-expanding the origin group, announcing the
/// return). Lives outside the view so the single-net-change gate — the part
/// that keeps a bulk drain from expanding N groups and firing N announcements —
/// is reachable from a test.
enum SidebarLiftedSectionTransition {
    /// The one workspace that left the section, or `nil` when the change was
    /// anything else: an addition, a no-op reorder, or a bulk change.
    ///
    /// Bulk is the case that matters. Clear All Notifications and toggling the
    /// section off both drain the whole list at once, and neither should read as
    /// N individual returns. Mirrors the pin handler's `added + removed == 1`
    /// gate so the two synthetic sections behave the same way.
    static func singleRemoval(
        from oldIDs: [TerminalSession.ID],
        to newIDs: [TerminalSession.ID]
    ) -> TerminalSession.ID? {
        let added = Set(newIDs).subtracting(oldIDs)
        let removed = Set(oldIDs).subtracting(newIDs)
        guard added.count + removed.count == 1 else { return nil }
        return removed.first
    }

    /// The one workspace that joined the section, under the same single-net-change
    /// gate as `singleRemoval` — a batch of agents going idle together must not
    /// read as N separate announcements.
    static func singleAddition(
        from oldIDs: [TerminalSession.ID],
        to newIDs: [TerminalSession.ID]
    ) -> TerminalSession.ID? {
        let added = Set(newIDs).subtracting(oldIDs)
        let removed = Set(oldIDs).subtracting(newIDs)
        guard added.count + removed.count == 1 else { return nil }
        return added.first
    }

    /// Whether an arrival needs its own spoken announcement.
    ///
    /// Only the unanswered-turn source does. A workspace arriving with a real
    /// attention reason is already spoken by `WorkspaceAttentionAnnouncementTracker`,
    /// and two announcements for one event is worse than none — but the tracker
    /// structurally cannot reach this source, since it speaks a crossing into
    /// `.needsAttention`/`.done`/`.error` and an idle prompt produces none of them.
    ///
    /// Out here rather than in the view body for the same reason as the gate
    /// above: this is the part that decides whether a VoiceOver user hears
    /// anything at all, so it has to be reachable from a test.
    static func announcesArrival(
        of session: TerminalSession,
        unansweredTurnPaneIDs: Set<TerminalPane.ID>
    ) -> Bool {
        !session.needsUserInput && session.hasUnansweredTurn(in: unansweredTurnPaneIDs)
    }
}
