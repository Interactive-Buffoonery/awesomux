import Testing
import Foundation
@testable import AwesoMuxCore

@Suite("SessionAgentRollup")
struct SessionAgentRollupTests {
    private func snapshot(
        _ kind: AgentKind = .shell,
        _ state: AgentDisplayState = .idle,
        unread: Int = 0,
        quitRisk: Bool = false,
        needsAck: Bool? = nil
    ) -> (id: UUID, snap: PaneAgentSnapshot) {
        let id = UUID()
        return (id, PaneAgentSnapshot(
            paneID: id,
            agentKind: kind,
            state: state,
            unread: unread,
            isQuitRisk: quitRisk,
            // Default to the chrome state so existing fixtures behave as before;
            // the C1 test below pins the real per-pane attention path.
            needsAcknowledgement: needsAck ?? (state == .needsAttention)
        ))
    }

    @Test("attentionPaneIDs is exactly the workspace's acknowledgement set")
    func attentionPaneIDsMatchAckSet() {
        // C1: `attentionPaneIDs` must equal the set of panes with
        // `attentionReason != nil` — the same condition as
        // `TerminalSession.needsAcknowledgement` — not infer it from the
        // chrome-collapsed display state.
        let needy = TerminalPane(
            title: "a", workingDirectory: "~", agentKind: .codex,
            attentionReason: .permissionPrompt,
            executionPlan: .local
        )
        let calm = TerminalPane(
            title: "b", workingDirectory: "~", agentKind: .claudeCode,
            agentExecutionState: .done,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(needy),
                second: .pane(calm)
            )),
            activePaneID: needy.id
        )

        let rollup = session.agentRollup()
        let ackSet = Set(session.panes.filter { $0.attentionReason != nil }.map(\.id))
        #expect(Set(rollup.attentionPaneIDs) == ackSet)
        #expect(Set(rollup.attentionPaneIDs) == [needy.id])
        #expect(session.needsAcknowledgement == !rollup.attentionPaneIDs.isEmpty)
    }

    @Test("Loudest pane wins by priority and carries its own id + kind")
    func loudestWins() {
        // A shell pane is merely .output; a Codex sibling needs attention.
        // The rollup must surface needsAttention AND name the Codex pane,
        // not the active/first one — otherwise the icon says "Shell needs input".
        let a = snapshot(.shell, .output)
        let b = snapshot(.codex, .needsAttention)
        let rollup = SessionAgentRollup.from([a.snap, b.snap])

        #expect(rollup?.state == .needsAttention)
        #expect(rollup?.winningPaneID == b.id)
        #expect(rollup?.winningAgentKind == .codex)
    }

    @Test("Unread is summed across panes")
    func unreadSummed() {
        let a = snapshot(.claudeCode, .output, unread: 2)
        let b = snapshot(.codex, .running, unread: 3)
        let rollup = SessionAgentRollup.from([a.snap, b.snap])

        #expect(rollup?.unreadTotal == 5)
    }

    @Test("Every attention-bearing pane is listed, not just the winner")
    func attentionPanesListed() {
        let a = snapshot(.claudeCode, .needsAttention)
        let b = snapshot(.codex, .needsAttention)
        let c = snapshot(.shell, .idle)
        let rollup = SessionAgentRollup.from([a.snap, b.snap, c.snap])

        #expect(rollup?.attentionPaneIDs.count == 2)
        #expect(rollup?.attentionPaneIDs.contains(a.id) == true)
        #expect(rollup?.attentionPaneIDs.contains(b.id) == true)
        #expect(rollup?.attentionPaneIDs.contains(c.id) == false)
    }

    @Test("Quit-risk panes are listed independently of display state")
    func quitRiskListed() {
        let a = snapshot(.claudeCode, .running, quitRisk: true)
        let b = snapshot(.shell, .idle, quitRisk: false)
        let rollup = SessionAgentRollup.from([a.snap, b.snap])

        #expect(rollup?.quitRiskPaneIDs == [a.id])
    }

    @Test("Tie on priority is stable: first pane in order wins")
    func tieIsStable() {
        let a = snapshot(.claudeCode, .needsAttention)
        let b = snapshot(.codex, .needsAttention)
        let rollup = SessionAgentRollup.from([a.snap, b.snap])

        #expect(rollup?.winningPaneID == a.id)
    }

    @Test("Empty input yields nil (a session always has >= 1 pane)")
    func emptyIsNil() {
        #expect(SessionAgentRollup.from([]) == nil)
    }
}
