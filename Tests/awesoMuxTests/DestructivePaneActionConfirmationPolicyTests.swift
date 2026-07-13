import AwesoMuxConfig
import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("DestructivePaneActionConfirmationPolicy")
struct DestructivePaneActionConfirmationPolicyTests {
    @Test("single risky pane prompts for shell restart")
    func singleRiskyPanePromptsForShellRestart() {
        let session = TerminalSession(
            title: "Agent",
            workingDirectory: "/tmp",
            agentKind: .claudeCode,
            agentExecutionState: .thinking
        )

        let decision = DestructivePaneActionConfirmationPolicy.decision(
            session: session,
            workspaces: .defaultValue
        )

        #expect(decision == .prompt(.restartShell))
    }

    @Test("multi-pane risky active pane prompts for pane close")
    func multiPaneRiskyActivePanePromptsForPaneClose() {
        let riskyPane = pane(title: "Risky", agentExecutionState: .thinking)
        let idlePane = pane(title: "Idle")
        let session = splitSession(activePane: riskyPane, otherPane: idlePane)

        let decision = DestructivePaneActionConfirmationPolicy.decision(
            session: session,
            workspaces: .defaultValue
        )

        #expect(decision == .prompt(.closePane))
    }

    @Test("non-risky panes proceed without prompt")
    func nonRiskyPanesProceedWithoutPrompt() {
        let single = TerminalSession(title: "Shell", workingDirectory: "/tmp")
        let first = pane(title: "First")
        let second = pane(title: "Second")
        let split = splitSession(activePane: first, otherPane: second)

        #expect(
            DestructivePaneActionConfirmationPolicy.decision(
                session: single,
                workspaces: .defaultValue
            ) == .proceedWithoutPrompt(.restartShell)
        )
        #expect(
            DestructivePaneActionConfirmationPolicy.decision(
                session: split,
                workspaces: .defaultValue
            ) == .proceedWithoutPrompt(.closePane)
        )
    }

    @Test("risky sibling does not prompt when active pane is safe")
    func riskySiblingDoesNotPromptWhenActivePaneIsSafe() {
        let active = pane(title: "Active")
        let riskySibling = pane(title: "Risky sibling", agentExecutionState: .thinking)
        let session = splitSession(activePane: active, otherPane: riskySibling)

        let decision = DestructivePaneActionConfirmationPolicy.decision(
            session: session,
            workspaces: .defaultValue
        )

        #expect(decision == .proceedWithoutPrompt(.closePane))
    }

    @Test("disabled setting proceeds without prompt for risky panes")
    func disabledSettingProceedsWithoutPromptForRiskyPanes() {
        let session = TerminalSession(
            title: "Agent",
            workingDirectory: "/tmp",
            agentKind: .claudeCode,
            agentExecutionState: .thinking
        )
        let workspaces = WorkspaceConfig(
            confirmDestructivePaneActionWithRunningAgent: false
        )

        let decision = DestructivePaneActionConfirmationPolicy.decision(
            session: session,
            workspaces: workspaces
        )

        #expect(decision == .proceedWithoutPrompt(.restartShell))
    }

    private func pane(
        title: String,
        agentExecutionState: AgentExecutionState = .idle
    ) -> TerminalPane {
        TerminalPane(
            title: title,
            workingDirectory: "/tmp",
            agentKind: agentExecutionState == .idle ? .shell : .claudeCode,
            agentExecutionState: agentExecutionState,
            executionPlan: .local
        )
    }

    private func splitSession(
        activePane: TerminalPane,
        otherPane: TerminalPane
    ) -> TerminalSession {
        TerminalSession(
            title: "Split",
            workingDirectory: "/tmp",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(activePane),
                second: .pane(otherPane)
            )),
            activePaneID: activePane.id
        )
    }
}
