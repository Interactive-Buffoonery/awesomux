import Testing
import Foundation
@testable import AwesoMuxCore

@Suite("INT-504 per-pane rollup")
struct PerPaneRollupTests {
    private func splitSession(
        first: TerminalPane,
        second: TerminalPane,
        active: TerminalPane.ID? = nil
    ) -> TerminalSession {
        TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(first),
                second: .pane(second)
            )),
            activePaneID: active ?? first.id
        )
    }

    @Test("loudest pane wins the badge and carries its own kind")
    func loudestPaneWinsBadge() {
        // Active pane is a shell merely producing output; the sibling Codex pane
        // needs input. The rollup must surface needsAttention AND name Codex.
        let shell = TerminalPane(
            title: "shell", workingDirectory: "~", agentKind: .shell,
            agentExecutionState: .output,
            executionPlan: .local
        )
        let codex = TerminalPane(
            title: "codex", workingDirectory: "~", agentKind: .codex,
            attentionReason: .permissionPrompt,
            executionPlan: .local
        )
        let session = splitSession(first: shell, second: codex, active: shell.id)

        let rollup = session.agentRollup()
        #expect(rollup.state == .needsAttention)
        #expect(rollup.winningPaneID == codex.id)
        #expect(rollup.winningAgentKind == .codex)
        #expect(session.effectiveChromeState == .needsAttention)
    }

    @Test("unread is summed across panes")
    func unreadSummed() {
        let a = TerminalPane(
            title: "a", workingDirectory: "~", agentKind: .codex,
            unreadNotificationCount: 2,
            executionPlan: .local
        )
        let b = TerminalPane(
            title: "b", workingDirectory: "~", agentKind: .claudeCode,
            unreadNotificationCount: 3,
            executionPlan: .local
        )
        let session = splitSession(first: a, second: b)
        #expect(session.unreadNotificationCount == 5)
        #expect(session.agentRollup().unreadTotal == 5)
    }

    @Test("any pane needing input makes the session need acknowledgement")
    func anyPaneNeedsAck() {
        let calm = TerminalPane(title: "a", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        let needy = TerminalPane(
            title: "b", workingDirectory: "~", agentKind: .codex,
            attentionReason: .userInputRequired,
            executionPlan: .local
        )
        let session = splitSession(first: calm, second: needy, active: calm.id)
        #expect(session.needsAcknowledgement == true)
        #expect(session.agentRollup().attentionPaneIDs == [needy.id])
    }

    @Test("any pane at quit risk makes the session a quit risk")
    func anyPaneQuitRisk() {
        let safe = TerminalPane(title: "a", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        var risky = TerminalPane(title: "b", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        risky.needsTerminalQuitConfirmation = true
        risky.terminalPromptObserved = true
        let session = splitSession(first: safe, second: risky, active: safe.id)
        #expect(session.isQuitRisk() == true)
        #expect(session.agentRollup().quitRiskPaneIDs == [risky.id])
    }

    @Test("activeAgentKind follows the active pane, not the loudest")
    func activeAgentKindFollowsActivePane() {
        let shell = TerminalPane(title: "a", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        let codex = TerminalPane(
            title: "b", workingDirectory: "~", agentKind: .codex,
            attentionReason: .permissionPrompt,
            executionPlan: .local
        )
        let session = splitSession(first: shell, second: codex, active: shell.id)
        // The loudest pane is Codex, but the active pane is the shell.
        #expect(session.activeAgentKind == .shell)
        #expect(session.agentRollup().winningAgentKind == .codex)
    }
}
