import AwesoMuxBridgeProtocol
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

    @Test("Oversized Unicode query is rejected before building row haystacks")
    func oversizedUnicodeQueryIsRejectedBeforeRowWork() {
        let group = SessionGroup(name: "Work", sessions: [makeSession(title: "Alpha")])
        let query = String(repeating: "🧑🏽‍💻", count: FuzzyMatcher.maxQueryLength + 1)
        var haystackCallCount = 0

        let output = SidebarSearchProjection.project(
            groups: [group],
            query: query,
            haystacks: { session in
                haystackCallCount += 1
                return self.haystacks(for: session)
            }
        )

        #expect(query.count == FuzzyMatcher.maxQueryLength + 1)
        #expect(haystackCallCount == 0)
        #expect(output.entries.isEmpty)
        #expect(output.topMatch == nil)
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
}
