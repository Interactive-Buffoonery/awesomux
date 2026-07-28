import Foundation

/// Post-pinned projection that lifts workspaces awaiting a human answer into the
/// sidebar's synthetic Needs Input section and hides them inside their origin
/// groups. Membership is computed, never stored — acknowledging a workspace
/// flips `needsUserInput` and the row re-renders at its unchanged index in its
/// group, exactly like unpinning.
///
/// Chained AFTER `SidebarPinnedProjection` over its reduced `entries`, so a
/// pinned workspace is already gone from the input and can never be lifted
/// twice: pinned wins by construction, with no precedence check.
public enum SidebarAttentionProjection {
    /// The single definition of membership. `SessionStore.liftedSessionIDs`
    /// reuses it so the rendered section, the ⌘-jump order, and the Dock menu
    /// can never disagree about what is lifted.
    ///
    /// Deliberately blind to the selection: the sticky ID is written in reaction
    /// to a selection change, so any render pass can observe a new selection
    /// against a not-yet-updated sticky. Excluding the selected session here
    /// would demote a just-clicked row for one pass and lift it back the next.
    public static func isLifted(
        _ session: TerminalSession,
        stickySessionID: TerminalSession.ID?
    ) -> Bool {
        session.id == stickySessionID || session.needsUserInput
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
        stickySessionID: TerminalSession.ID?,
        isFiltering: Bool,
        searchTopMatch: TerminalSession.ID?
    ) -> Output {
        var attention: [LiftedSessionEntry] = []
        var remaining: [SidebarGroupEntry] = []
        remaining.reserveCapacity(entries.count)

        for groupEntry in entries {
            var kept: [SidebarSessionEntry] = []
            kept.reserveCapacity(groupEntry.sessions.count)
            for sessionEntry in groupEntry.sessions {
                if isLifted(sessionEntry.session, stickySessionID: stickySessionID) {
                    attention.append(
                        LiftedSessionEntry(
                            entry: sessionEntry,
                            originGroup: groupEntry.group,
                            originGroupUnfilteredIndex: groupEntry.unfilteredIndex
                        )
                    )
                } else {
                    kept.append(sessionEntry)
                }
            }
            // Mirrors SidebarPinnedProjection: while filtering, a group whose
            // only matches were lifted has nothing left to show; unfiltered
            // empty groups stay so the empty-group drop target keeps working.
            if kept.isEmpty && isFiltering { continue }
            remaining.append(
                SidebarGroupEntry(
                    group: groupEntry.group,
                    unfilteredIndex: groupEntry.unfilteredIndex,
                    sessions: kept
                )
            )
        }

        // Needs Input renders above every other section, so while filtering the
        // "first visible match" Return commits to is a lifted match when one
        // exists.
        let topMatch =
            isFiltering
            ? (attention.first?.entry.session.id ?? searchTopMatch)
            : nil
        return Output(attention: attention, entries: remaining, topMatch: topMatch)
    }
}
