import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("SidebarSearchProjection")
struct SidebarSearchProjectionTests {

    private func haystacks(for session: TerminalSession) -> SidebarSearchHaystacks {
        SidebarSearchHaystacks(
            title: session.title,
            location: session.workingDirectory,
            agentState: SidebarAgentStateSearchToken(agentState: session.agentState)
        )
    }

    private func makeSession(
        title: String,
        cwd: String = "~/code",
        agentKind: AgentKind = .claudeCode,
        agentState: AgentState = .idle
    ) -> TerminalSession {
        TerminalSession(
            title: title,
            workingDirectory: cwd,
            agentKind: agentKind,
            agentState: agentState
        )
    }

    @Test(
        "Every display state maps to one canonical search token",
        arguments: [
            (AgentDisplayState.needsAttention, SidebarAgentStateSearchToken.needs),
            (.error, .error),
            (.thinking, .thinking),
            (.done, .done),
            (.output, .output),
            (.waiting, .waiting),
            (.running, .running),
            (.idle, .idle),
        ]
    )
    func canonicalStateTokens(
        state: AgentDisplayState,
        expectedToken: SidebarAgentStateSearchToken
    ) {
        #expect(SidebarAgentStateSearchToken(agentState: state) == expectedToken)
    }

    @Test("Canonical state token returns whole-row matches without highlight ranges")
    func stateTokenMatchesWholeRow() throws {
        let needs = makeSession(title: "Alpha", agentState: .needsAttention)
        let thinking = makeSession(title: "Beta", agentState: .thinking)

        let output = SidebarSearchProjection.project(
            groups: [SessionGroup(name: "Work", sessions: [needs, thinking])],
            query: "needs",
            haystacks: haystacks(for:)
        )

        let entry = try #require(output.entries.first?.sessions.first)
        let match = try #require(entry.match)
        #expect(output.entries[0].sessions.count == 1)
        #expect(entry.session.id == needs.id)
        #expect(match.field == .agentState)
        #expect(match.ranges.isEmpty)
    }

    @Test("Canonical state tokens are exact and case-insensitive")
    func stateTokensAreExactAndCaseInsensitive() {
        let thinking = makeSession(title: "Alpha", agentState: .thinking)
        let group = SessionGroup(name: "Work", sessions: [thinking])

        let exact = SidebarSearchProjection.project(
            groups: [group],
            query: "THINKING",
            haystacks: haystacks(for:)
        )
        let partial = SidebarSearchProjection.project(
            groups: [group],
            query: "think",
            haystacks: haystacks(for:)
        )

        #expect(exact.entries.first?.sessions.first?.session.id == thinking.id)
        #expect(partial.entries.isEmpty)
    }

    @Test("Reserved state token does not fuzzy-match title or location")
    func stateTokenExcludesVisibleTextFalsePositives() {
        let titleFalsePositive = makeSession(title: "Needs migration", agentState: .idle)
        let locationFalsePositive = makeSession(title: "Alpha", cwd: "~/needs-work", agentState: .idle)
        let needs = makeSession(title: "Beta", agentState: .needsAttention)

        let output = SidebarSearchProjection.project(
            groups: [
                SessionGroup(
                    name: "Work",
                    sessions: [titleFalsePositive, locationFalsePositive, needs]
                )
            ],
            query: "needs",
            haystacks: haystacks(for:)
        )

        #expect(output.entries[0].sessions.map(\.session.id) == [needs.id])
    }

    @Test("Empty query returns every session in original order with no matches")
    func emptyQueryPassthrough() {
        let group = SessionGroup(
            name: "Work",
            sessions: [
                makeSession(title: "Alpha"),
                makeSession(title: "Beta"),
                makeSession(title: "Gamma"),
            ])

        let output = SidebarSearchProjection.project(
            groups: [group],
            query: "",
            haystacks: haystacks(for:)
        )

        #expect(output.entries.count == 1)
        #expect(output.entries[0].sessions.map(\.session.title) == ["Alpha", "Beta", "Gamma"])
        #expect(output.entries[0].sessions.allSatisfy { $0.match == nil })
        #expect(output.topMatch == nil)
    }

    @Test("Filtered group drops sessions that don't match")
    func filtersUnmatched() {
        let group = SessionGroup(
            name: "Work",
            sessions: [
                makeSession(title: "Claude Code"),
                makeSession(title: "Random", cwd: "~/elsewhere"),
                makeSession(title: "Codex"),
            ])

        let output = SidebarSearchProjection.project(
            groups: [group],
            query: "co",
            haystacks: haystacks(for:)
        )

        let titles = output.entries[0].sessions.map(\.session.title)
        #expect(titles.contains("Claude Code"))
        #expect(titles.contains("Codex"))
        #expect(!titles.contains("Random"))
    }

    @Test("Group with no matching session is omitted entirely")
    func dropsEmptyGroup() {
        let groups = [
            SessionGroup(name: "Work", sessions: [makeSession(title: "Alpha")]),
            SessionGroup(name: "Personal", sessions: [makeSession(title: "Beta")]),
        ]

        let output = SidebarSearchProjection.project(
            groups: groups,
            query: "alph",
            haystacks: haystacks(for:)
        )

        #expect(output.entries.count == 1)
        #expect(output.entries[0].group.name == "Work")
    }

    @Test("Within-group sort is score-desc with stable sidebar-order tiebreak")
    func sortByScoreStableTiebreak() throws {
        // Two sessions tie on score (both single-char word-boundary matches);
        // original order must win.
        let group = SessionGroup(
            name: "Work",
            sessions: [
                makeSession(title: "Apple"),
                makeSession(title: "Apricot"),
                makeSession(title: "Avocado"),
                makeSession(title: "Banana"),  // no 'a' at boundary
            ])

        let output = SidebarSearchProjection.project(
            groups: [group],
            query: "a",
            haystacks: haystacks(for:)
        )

        let sessions = output.entries[0].sessions
        let titles = sessions.map(\.session.title)
        #expect(titles.prefix(3) == ["Apple", "Apricot", "Avocado"])
        #expect(titles.last == "Banana")

        // Also pin the actual score-equality property the test is named for —
        // without this the test would still pass on order alone if scoring
        // shifted Apple/Apricot/Avocado apart and lost the tiebreak property.
        let topThreeScores = try sessions.prefix(3).map {
            try #require($0.match?.score)
        }
        #expect(Set(topThreeScores).count == 1, "Apple/Apricot/Avocado should all tie on score")
    }

    @Test("Highlight ranges anchor to the abbreviated path the view actually renders")
    func highlightRangesOnAbbreviatedPath() throws {
        // SidebarView passes the rendered sidebar location as the haystack so
        // highlight ranges line up with what the user sees.
        // This test pins that contract from the projection's perspective.
        let abbreviated = "~/Obsidian/ProjectNotes"
        let session = makeSession(title: "noisy", cwd: "/Users/me/Obsidian/ProjectNotes")

        let output = SidebarSearchProjection.project(
            groups: [SessionGroup(name: "g", sessions: [session])],
            query: "obs",
            haystacks: { _ in
                SidebarSearchHaystacks(
                    title: "noisy",
                    location: abbreviated,
                    agentState: .idle
                )
            }
        )

        let match = try #require(output.entries[0].sessions[0].match)
        #expect(match.field == .location)
        // Ranges must slice cleanly into the abbreviated string.
        let extracted = match.ranges.map { String(abbreviated[$0]) }.joined()
        #expect(extracted == "Obs")
    }

    @Test("Top match is the first visible session of the first surviving group")
    func topMatchIsFirstVisible() {
        // Cross-group "global highest score" would jump Return to a row
        // visually below another lower-scoring result. Use first-visible
        // semantics so the keyboard target always matches what the user
        // sees as the top result.
        let groups = [
            SessionGroup(
                name: "First",
                sessions: [
                    makeSession(title: "axxxxclaude")  // mid-word, weaker match
                ]),
            SessionGroup(
                name: "Second",
                sessions: [
                    makeSession(title: "Claude Code")  // higher score in isolation
                ]),
        ]

        let output = SidebarSearchProjection.project(
            groups: groups,
            query: "cl",
            haystacks: haystacks(for:)
        )

        // Even though "Claude Code" scores higher than "axxxxclaude",
        // the first-visible session of the first surviving group wins.
        #expect(output.topMatch == groups[0].sessions[0].id)
    }

    @Test("Field-precedence: title beats location at equal score")
    func fieldPrecedenceTitleBeatsLocation() throws {
        // 'a' matches both title (start) and location (start) at score 9 each.
        let session = makeSession(title: "a-thing", cwd: "a-dir")
        let output = SidebarSearchProjection.project(
            groups: [SessionGroup(name: "g", sessions: [session])],
            query: "a",
            haystacks: { _ in
                SidebarSearchHaystacks(
                    title: "a-thing",
                    location: "a-dir",
                    agentState: .idle
                )
            }
        )

        let match = try #require(output.entries[0].sessions[0].match)
        #expect(match.field == .title)
    }

    @Test("Filtering preserves the group's unfilteredIndex for stable tinting")
    func preservesUnfilteredIndex() {
        let groups = [
            SessionGroup(name: "Zero", sessions: [makeSession(title: "match-here")]),
            SessionGroup(name: "One", sessions: [makeSession(title: "no")]),
            SessionGroup(name: "Two", sessions: [makeSession(title: "match-too")]),
        ]

        let output = SidebarSearchProjection.project(
            groups: groups,
            query: "match",
            haystacks: haystacks(for:)
        )

        // "One" was filtered out; remaining groups keep their original indices.
        #expect(output.entries.map(\.unfilteredIndex) == [0, 2])
    }

    @Test("Top match is nil when no query is active")
    func topMatchNilWithoutQuery() {
        let group = SessionGroup(name: "Work", sessions: [makeSession(title: "Anything")])
        let output = SidebarSearchProjection.project(
            groups: [group],
            query: "",
            haystacks: haystacks(for:)
        )
        #expect(output.topMatch == nil)
    }
}
