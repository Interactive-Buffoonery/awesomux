import Foundation

public struct SessionMatch: Equatable, Sendable {
    public enum Field: Int, Equatable, Sendable {
        case title = 0
        case location = 1
    }

    public let field: Field
    public let score: Int
    public let ranges: [Range<String.Index>]

    public init(field: Field, score: Int, ranges: [Range<String.Index>]) {
        self.field = field
        self.score = score
        self.ranges = ranges
    }
}

public struct SidebarSessionEntry: Equatable, Sendable {
    public let session: TerminalSession
    /// nil when no query is active or this session matched only by virtue of
    /// the no-filter passthrough.
    public let match: SessionMatch?

    public init(session: TerminalSession, match: SessionMatch?) {
        self.session = session
        self.match = match
    }
}

public struct SidebarGroupEntry: Equatable, Sendable {
    public let group: SessionGroup
    /// Position of the group in the original unfiltered store. Pinned so
    /// project-tint colors don't shift as the user types.
    public let unfilteredIndex: Int
    public let sessions: [SidebarSessionEntry]

    public init(group: SessionGroup, unfilteredIndex: Int, sessions: [SidebarSessionEntry]) {
        self.group = group
        self.unfilteredIndex = unfilteredIndex
        self.sessions = sessions
    }
}

/// Per-session haystacks the projection scores against. The view layer
/// supplies these so the sidebar's displayed location (abbreviated local cwd
/// or remote host) is what the user types against and what gets highlighted.
///
/// Agent kind is intentionally NOT a haystack: the sidebar row renders the
/// agent as an icon, not text, so matches there would show up with no visible
/// highlight explaining the result (a short query like `c` would otherwise
/// pull in every Codex/Claude session indiscriminately).
public struct SidebarSearchHaystacks: Equatable, Sendable {
    public let title: String
    public let location: String

    public init(title: String, location: String) {
        self.title = title
        self.location = location
    }
}

/// Pure projection from session-store state + a search query to the filtered,
/// sorted entries the sidebar renders. Lives in `AwesoMuxCore` so the
/// non-trivial filter/sort/top-result logic is directly unit-testable without
/// a SwiftUI host.
public enum SidebarSearchProjection {
    public struct Output: Equatable, Sendable {
        public let entries: [SidebarGroupEntry]
        /// Identity of the **first visible** matched session when a query is
        /// active — the first session of the first surviving group. This is
        /// what Return commits to so the keyboard target always matches what
        /// the user sees at the top. Cross-group "global highest score"
        /// ranking would otherwise jump Return to a row visually below
        /// another lower-scoring result. Nil when no query is active or no
        /// results matched.
        public let topMatch: TerminalSession.ID?

        public init(entries: [SidebarGroupEntry], topMatch: TerminalSession.ID?) {
            self.entries = entries
            self.topMatch = topMatch
        }
    }

    /// - Parameters:
    ///   - groups: session groups in their unfiltered order
    ///   - query: already-normalized (trimmed) query string; empty disables filtering
    ///   - haystacks: per-session searchable strings
    public static func project(
        groups: [SessionGroup],
        query: String,
        haystacks: (TerminalSession) -> SidebarSearchHaystacks
    ) -> Output {
        let isFiltering = !query.isEmpty
        var entries: [SidebarGroupEntry] = []
        entries.reserveCapacity(groups.count)

        for (groupIndex, group) in groups.enumerated() {
            if !isFiltering {
                let sessions = group.sessions.map { SidebarSessionEntry(session: $0, match: nil) }
                entries.append(
                    SidebarGroupEntry(group: group, unfilteredIndex: groupIndex, sessions: sessions)
                )
                continue
            }

            var matched: [(entry: SidebarSessionEntry, originalIndex: Int)] = []
            matched.reserveCapacity(group.sessions.count)

            for (sessionIndex, session) in group.sessions.enumerated() {
                guard let match = Self.bestMatch(for: session, query: query, haystacks: haystacks(session)) else {
                    continue
                }
                matched.append(
                    (SidebarSessionEntry(session: session, match: match), sessionIndex)
                )
            }

            guard !matched.isEmpty else { continue }

            // Score desc; stable tiebreak on original sidebar order.
            matched.sort { lhs, rhs in
                let lhsScore = lhs.entry.match?.score ?? 0
                let rhsScore = rhs.entry.match?.score ?? 0
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return lhs.originalIndex < rhs.originalIndex
            }

            entries.append(
                SidebarGroupEntry(
                    group: group,
                    unfilteredIndex: groupIndex,
                    sessions: matched.map(\.entry)
                )
            )
        }

        // topMatch is the first visible session of the first surviving
        // group — keeps the Return-target consistent with what the user
        // sees as "the top result," even when a later group's session has
        // a higher score in isolation.
        let topMatch = isFiltering ? entries.first?.sessions.first?.session.id : nil

        return Output(entries: entries, topMatch: topMatch)
    }

    /// Try each haystack; if multiple match, prefer the highest score. Ties
    /// break by declared field precedence (title > location) so the
    /// highlighted field doesn't depend on iteration order.
    private static func bestMatch(
        for session: TerminalSession,
        query: String,
        haystacks: SidebarSearchHaystacks
    ) -> SessionMatch? {
        let candidates: [(field: SessionMatch.Field, haystack: String)] = [
            (.title, haystacks.title),
            (.location, haystacks.location)
        ]

        var best: SessionMatch?
        for (field, haystack) in candidates {
            guard let result = FuzzyMatcher.match(query: query, in: haystack) else { continue }
            let candidate = SessionMatch(field: field, score: result.score, ranges: result.ranges)
            guard let current = best else {
                best = candidate
                continue
            }
            if candidate.score > current.score {
                best = candidate
            } else if candidate.score == current.score && candidate.field.rawValue < current.field.rawValue {
                best = candidate
            }
        }
        return best
    }
}
