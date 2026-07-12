import Foundation

public struct PinnedSessionEntry: Equatable, Sendable {
    public let entry: SidebarSessionEntry
    public let originGroup: SessionGroup
    public let originGroupUnfilteredIndex: Int

    public init(
        entry: SidebarSessionEntry,
        originGroup: SessionGroup,
        originGroupUnfilteredIndex: Int
    ) {
        self.entry = entry
        self.originGroup = originGroup
        self.originGroupUnfilteredIndex = originGroupUnfilteredIndex
    }
}

/// Post-search projection that floats pinned sessions into the sidebar's
/// synthetic Pinned section and hides them inside their origin groups.
/// Pinning never moves a session in the store — this projection is the only
/// place pin membership affects layout, which is what makes unpin
/// return-to-origin structurally free (INT-737).
public enum SidebarPinnedProjection {
    public struct Output: Equatable, Sendable {
        public let pinned: [PinnedSessionEntry]
        public let entries: [SidebarGroupEntry]
        public let topMatch: TerminalSession.ID?

        public init(
            pinned: [PinnedSessionEntry],
            entries: [SidebarGroupEntry],
            topMatch: TerminalSession.ID?
        ) {
            self.pinned = pinned
            self.entries = entries
            self.topMatch = topMatch
        }
    }

    public static func apply(
        entries: [SidebarGroupEntry],
        pinnedSessionIDs: [TerminalSession.ID],
        isFiltering: Bool,
        searchTopMatch: TerminalSession.ID?
    ) -> Output {
        guard !pinnedSessionIDs.isEmpty else {
            return Output(
                pinned: [],
                entries: entries,
                topMatch: isFiltering ? searchTopMatch : nil
            )
        }

        let pinnedIDSet = Set(pinnedSessionIDs)
        var pinnedByID: [TerminalSession.ID: PinnedSessionEntry] = [:]
        var remaining: [SidebarGroupEntry] = []
        remaining.reserveCapacity(entries.count)

        for groupEntry in entries {
            var kept: [SidebarSessionEntry] = []
            kept.reserveCapacity(groupEntry.sessions.count)
            for sessionEntry in groupEntry.sessions {
                if pinnedIDSet.contains(sessionEntry.session.id) {
                    pinnedByID[sessionEntry.session.id] = PinnedSessionEntry(
                        entry: sessionEntry,
                        originGroup: groupEntry.group,
                        originGroupUnfilteredIndex: groupEntry.unfilteredIndex
                    )
                } else {
                    kept.append(sessionEntry)
                }
            }
            // While filtering, a group whose only matches were pinned has
            // nothing left to show; unfiltered empty groups stay so the
            // empty-group drop target keeps working.
            if kept.isEmpty && isFiltering { continue }
            remaining.append(
                SidebarGroupEntry(
                    group: groupEntry.group,
                    unfilteredIndex: groupEntry.unfilteredIndex,
                    sessions: kept
                )
            )
        }

        let pinned = pinnedSessionIDs.compactMap { pinnedByID[$0] }
        // The Pinned section renders above every group, so while filtering the
        // "first visible match" Return commits to is a pinned match when one
        // exists.
        let topMatch = isFiltering
            ? (pinned.first?.entry.session.id ?? searchTopMatch)
            : nil
        return Output(pinned: pinned, entries: remaining, topMatch: topMatch)
    }
}
