import AwesoMuxBridgeProtocol
import Testing
@testable import AwesoMuxCore
import Foundation

@Suite("AgentActivityRoster")
struct AgentActivityRosterTests {
    private func snapshot(
        _ kind: AgentKind,
        _ state: AgentDisplayState,
        paneID: UUID = UUID()
    ) -> PaneAgentSnapshot {
        PaneAgentSnapshot(
            paneID: paneID,
            agentKind: kind,
            state: state,
            unread: 0,
            isQuitRisk: false,
            needsAcknowledgement: false
        )
    }

    @Test func excludesShellPanes() {
        let roster = AgentActivityRoster.build([
            .init(sessionID: UUID(), panes: [
                snapshot(.shell, .running),
                snapshot(.claudeCode, .thinking),
            ])
        ])
        #expect(roster.total == 1)
        #expect(roster.groups.count == 1)
        #expect(roster.groups[0].rows[0].agentKind == .claudeCode)
    }

    @Test func splitSessionYieldsOneRowPerAgentPane() {
        let sessionID = UUID()
        let claude = snapshot(.claudeCode, .needsAttention)
        let codex = snapshot(.codex, .thinking)
        let roster = AgentActivityRoster.build([
            .init(sessionID: sessionID, panes: [claude, codex])
        ])
        #expect(roster.total == 2)
        #expect(roster.groups.map(\.state) == [.needsAttention, .thinking])
        #expect(roster.groups[0].rows[0].paneID == claude.paneID)
        #expect(roster.groups[1].rows[0].sessionID == sessionID)
    }

    @Test func groupsOrderedByStatePriorityAndEmptyGroupsOmitted() {
        let roster = AgentActivityRoster.build([
            .init(sessionID: UUID(), panes: [
                snapshot(.codex, .idle),
                snapshot(.claudeCode, .error),
                snapshot(.pi, .done),
                snapshot(.openCode, .output),
            ])
        ])
        // priority order: error(2) < done(4) < output(5) < idle(8)
        #expect(roster.groups.map(\.state) == [.error, .done, .output, .idle])
        #expect(roster.groups.allSatisfy { !$0.rows.isEmpty })
    }

    @Test func rowsKeepInputOrderWithinAGroup() {
        let first = snapshot(.claudeCode, .thinking)
        let second = snapshot(.codex, .thinking)
        let roster = AgentActivityRoster.build([
            .init(sessionID: UUID(), panes: [first]),
            .init(sessionID: UUID(), panes: [second]),
        ])
        #expect(roster.groups[0].rows.map(\.paneID) == [first.paneID, second.paneID])
    }

    @Test func countsMatchRowsPerState() {
        let roster = AgentActivityRoster.build([
            .init(sessionID: UUID(), panes: [
                snapshot(.claudeCode, .thinking),
                snapshot(.codex, .thinking),
                snapshot(.shell, .running),
            ])
        ])
        #expect(roster.counts == [.thinking: 2])
        #expect(roster.total == 2)
    }

    @Test func emptyInputYieldsEmptyRoster() {
        let roster = AgentActivityRoster.build([])
        #expect(roster.groups.isEmpty)
        #expect(roster.counts.isEmpty)
        #expect(roster.total == 0)
    }
}
