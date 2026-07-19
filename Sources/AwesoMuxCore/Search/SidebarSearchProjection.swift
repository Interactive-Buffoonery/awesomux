import Foundation

public struct SessionMatch: Equatable, Sendable {
    public enum Field: Int, Equatable, Sendable {
        case title = 0
        case location = 1
        case agentState = 2
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

public enum SidebarAgentStateSearchToken: String, CaseIterable, Equatable, Sendable {
    case needs
    case error
    case thinking
    case done
    case output
    case waiting
    case running
    case idle

    public static let canonicalList = allCases.map(\.rawValue).joined(separator: ", ")

    public init(agentState: AgentDisplayState) {
        switch agentState {
        case .needsAttention:
            self = .needs
        case .error:
            self = .error
        case .thinking:
            self = .thinking
        case .done:
            self = .done
        case .output:
            self = .output
        case .waiting:
            self = .waiting
        case .running:
            self = .running
        case .idle:
            self = .idle
        }
    }

    public static func localizedSearchHelp(
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        String(
            localized:
                "Filters workspaces by title or location. Agent state tokens: \(canonicalList). Use needs for Needs input workspaces. Use Up and Down Arrow to focus a result, Return to open it, or Escape to clear.",
            bundle: bundle,
            locale: locale,
            comment: "Sidebar search help. Keep the interpolated canonical English agent-state tokens unchanged."
        )
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
/// Agent state is a canonical exact-match token rather than a fuzzy haystack.
/// A state-token match selects the whole row and carries no visible-text
/// highlight ranges.
///
/// Agent kind is intentionally NOT a haystack: the sidebar row renders the
/// agent as an icon, not text, so matches there would show up with no visible
/// highlight explaining the result (a short query like `c` would otherwise
/// pull in every Codex/Claude session indiscriminately).
public struct SidebarSearchHaystacks: Equatable, Sendable {
    public let title: String
    public let location: String
    public let agentState: SidebarAgentStateSearchToken

    public init(title: String, location: String, agentState: SidebarAgentStateSearchToken) {
        self.title = title
        self.location = location
        self.agentState = agentState
    }
}

/// Pure projection from session-store state + a search query to the filtered,
/// sorted entries the sidebar renders. Lives in `AwesoMuxCore` so the
/// non-trivial filter/sort/top-result logic is directly unit-testable without
/// a SwiftUI host.
public enum SidebarSearchProjection {
    private enum ParsedQuery {
        case agentState(SidebarAgentStateSearchToken)
        case fuzzy(String)

        init?(_ query: String) {
            guard !query.isEmpty, query.count <= FuzzyMatcher.maxQueryLength else { return nil }

            if let stateToken = SidebarAgentStateSearchToken(rawValue: query.lowercased()) {
                self = .agentState(stateToken)
            } else {
                self = .fuzzy(query)
            }
        }
    }

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
        let parsedQuery: ParsedQuery?
        if isFiltering {
            guard let query = ParsedQuery(query) else {
                return Output(entries: [], topMatch: nil)
            }
            parsedQuery = query
        } else {
            parsedQuery = nil
        }

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
                guard let parsedQuery,
                    let match = Self.bestMatch(query: parsedQuery, haystacks: haystacks(session))
                else {
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
        query: ParsedQuery,
        haystacks: SidebarSearchHaystacks
    ) -> SessionMatch? {
        switch query {
        case .agentState(let stateToken):
            guard stateToken == haystacks.agentState else { return nil }
            return SessionMatch(field: .agentState, score: 0, ranges: [])
        case .fuzzy(let query):
            return Self.bestFuzzyMatch(query: query, haystacks: haystacks)
        }
    }

    private static func bestFuzzyMatch(
        query: String,
        haystacks: SidebarSearchHaystacks
    ) -> SessionMatch? {
        let candidates: [(field: SessionMatch.Field, haystack: String)] = [
            (.title, haystacks.title),
            (.location, haystacks.location),
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
