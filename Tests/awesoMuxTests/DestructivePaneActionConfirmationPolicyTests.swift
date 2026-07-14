import AwesoMuxConfig
import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("DestructivePaneActionConfirmationPolicy")
struct DestructivePaneActionConfirmationPolicyTests {
    @Test("single-pane session is unavailable regardless of quit risk")
    func singlePaneSessionIsUnavailable() {
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

        // The caller (closeActivePane) routes single-pane sessions to
        // closeWorkspace(_:) before ever consulting this policy.
        #expect(decision == .unavailable)
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

        // Single-pane: caller routes to closeWorkspace(_:) before this policy runs.
        #expect(
            DestructivePaneActionConfirmationPolicy.decision(
                session: single,
                workspaces: .defaultValue
            ) == .unavailable
        )
        #expect(
            DestructivePaneActionConfirmationPolicy.decision(
                session: split,
                workspaces: .defaultValue
            ) == .proceedWithoutPrompt(.closePane)
        )
    }

    @Test("bridged away-from-prompt active pane prompts for pane close (quit-safe but close-risky)")
    func bridgedAwayFromPromptActivePanePromptsForPaneClose() {
        var bridgedPane = pane(title: "Bridged")
        bridgedPane.foregroundProcessLiveness = .bridged
        bridgedPane.needsTerminalQuitConfirmation = true
        bridgedPane.terminalPromptObserved = true
        let idlePane = pane(title: "Idle")
        let session = splitSession(activePane: bridgedPane, otherPane: idlePane)

        // `isQuitRisk` treats a bridged pane as always-safe (work survives app
        // quit), so the old gate would have returned `.proceedWithoutPrompt`
        // here. Pane close/restart destroys the daemon session too, so this
        // must go through `isCloseRisk` and prompt.
        let decision = DestructivePaneActionConfirmationPolicy.decision(
            session: session,
            workspaces: .defaultValue
        )

        #expect(decision == .prompt(.closePane))
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

    @Test("disabled setting does not resurrect single-pane restart decisions")
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

        // Single-pane is unavailable unconditionally; the caller routes to
        // closeWorkspace(_:) before this policy runs, so this setting has
        // no bearing on the single-pane path.
        #expect(decision == .unavailable)
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
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(activePane),
                    second: .pane(otherPane)
                )),
            activePaneID: activePane.id
        )
    }
}
