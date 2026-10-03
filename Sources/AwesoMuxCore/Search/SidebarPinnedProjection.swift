import Foundation

/// A session entry lifted out of its origin group into one of the sidebar's
/// synthetic top sections (Needs Input, Pinned). Carries the origin so the tile
/// keeps its group tint and can name where it will return to.
public struct LiftedSessionEntry: Equatable, Sendable {
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
        public let pinned: [LiftedSessionEntry]
        public let entries: [SidebarGroupEntry]
        public let topMatch: TerminalSession.ID?

        public init(
            pinned: [LiftedSessionEntry],
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
        let partition = SidebarLiftedPartition.apply(
            entries: entries,
            orderedSessionIDs: pinnedSessionIDs,
            isFiltering: isFiltering,
            searchTopMatch: searchTopMatch
        )
        return Output(pinned: partition.lifted, entries: partition.entries, topMatch: partition.topMatch)
    }
}

/// Shared ordered partition; each projection owns membership and precedence.
enum SidebarLiftedPartition {
    struct Output {
        let lifted: [LiftedSessionEntry]
        let entries: [SidebarGroupEntry]
        let topMatch: TerminalSession.ID?
    }

    static func apply(
        entries: [SidebarGroupEntry],
        orderedSessionIDs: [TerminalSession.ID],
        isFiltering: Bool,
        searchTopMatch: TerminalSession.ID?
    ) -> Output {
        guard !orderedSessionIDs.isEmpty else {
            return Output(
                lifted: [],
                entries: entries,
                topMatch: isFiltering ? searchTopMatch : nil
            )
        }

        let liftedIDSet = Set(orderedSessionIDs)
        var liftedByID: [TerminalSession.ID: LiftedSessionEntry] = [:]
        var remaining: [SidebarGroupEntry] = []
        remaining.reserveCapacity(entries.count)

        for groupEntry in entries {
            var kept: [SidebarSessionEntry] = []
            kept.reserveCapacity(groupEntry.sessions.count)
            for sessionEntry in groupEntry.sessions {
                if liftedIDSet.contains(sessionEntry.session.id) {
                    liftedByID[sessionEntry.session.id] = LiftedSessionEntry(
                        entry: sessionEntry,
                        originGroup: groupEntry.group,
                        originGroupUnfilteredIndex: groupEntry.unfilteredIndex
                    )
                } else {
                    kept.append(sessionEntry)
                }
            }
            // While filtering, a group whose only matches were lifted has
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

        let lifted = orderedSessionIDs.compactMap { liftedByID[$0] }
        // Lifted rows render above the remaining groups.
        let topMatch = isFiltering
            ? (lifted.first?.entry.session.id ?? searchTopMatch)
            : nil
        return Output(lifted: lifted, entries: remaining, topMatch: topMatch)
    }
}
