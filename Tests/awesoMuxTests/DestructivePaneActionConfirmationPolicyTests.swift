import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("DestructivePaneActionConfirmationPolicy")
struct DestructivePaneActionConfirmationPolicyTests {
    @Test("confirmed close needs no action when the target exited during the prompt")
    func confirmedCloseNeedsNoActionWhenTargetExitedDuringPrompt() {
        let target = pane(title: "Target", agentExecutionState: .thinking)
        let survivor = pane(title: "Survivor")
        let refreshed = TerminalSession(
            title: "Refreshed",
            workingDirectory: "/tmp",
            layout: .pane(survivor),
            activePaneID: survivor.id
        )

        #expect(
            DestructivePaneActionConfirmationPolicy.confirmedCloseAction(
                session: refreshed,
                targetPaneID: target.id
            ) == .alreadyClosed
        )
    }

    @Test("confirmed close becomes a workspace close when only the target remains")
    func confirmedCloseBecomesWorkspaceCloseWhenOnlyTargetRemains() {
        let target = pane(title: "Target", agentExecutionState: .thinking)
        let refreshed = TerminalSession(
            title: "Refreshed",
            workingDirectory: "/tmp",
            layout: .pane(target),
            activePaneID: target.id
        )

        #expect(
            DestructivePaneActionConfirmationPolicy.confirmedCloseAction(
                session: refreshed,
                targetPaneID: target.id
            ) == .closeWorkspace
        )
    }

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

    @Test("verified-idle bridged active pane closes without prompt before any prompt marker (#190)")
    func verifiedBridgedIdlePaneClosesWithoutPrompt() {
        // The issue #190 repro at the policy-consumer layer: reattached after a
        // relaunch (promptObserved reset, stale away-marker latched), but the
        // probe walked the daemon tree and found an idle shell.
        var bridgedPane = pane(title: "Bridged")
        bridgedPane.foregroundProcessLiveness = .bridged
        bridgedPane.terminalPromptObserved = false
        bridgedPane.needsTerminalQuitConfirmation = true
        let session = splitSession(activePane: bridgedPane, otherPane: pane(title: "Idle"))

        #expect(
            DestructivePaneActionConfirmationPolicy.decision(
                session: session,
                workspaces: .defaultValue
            ) == .proceedWithoutPrompt(.closePane)
        )
    }

    @Test("unverified bridged active pane still prompts before any prompt marker")
    func bridgedIndeterminatePanePrompts() {
        var bridgedPane = pane(title: "Bridged")
        bridgedPane.foregroundProcessLiveness = .bridgedIndeterminate
        bridgedPane.terminalPromptObserved = false
        let session = splitSession(activePane: bridgedPane, otherPane: pane(title: "Idle"))

        #expect(
            DestructivePaneActionConfirmationPolicy.decision(
                session: session,
                workspaces: .defaultValue
            ) == .prompt(.closePane)
        )
    }

    @Test("close-pane body names the live agent when that is the risk (#190)")
    func closePaneBodyNamesLiveAgent() {
        let body = DestructivePaneActionConfirmationPolicy.closePaneConfirmationBody(
            displayTitle: "Workspace",
            agentKind: .claudeCode,
            riskReason: .liveAgentProcess
        )
        #expect(body.contains("Claude Code"))
        // The title must survive too — with three positional placeholders
        // (agent, title, agent), a mis-mapped middle argument would otherwise
        // slip past an agent-name-only assertion.
        #expect(body.contains("Workspace"))
        #expect(!body.contains("has activity"))
    }

    @Test("close-pane body stays generic for non-agent risks")
    func closePaneBodyGenericForOtherRisks() {
        for reason in [QuitRiskReason.liveForegroundProcess, .terminalAwayFromPrompt, .indeterminate] {
            let body = DestructivePaneActionConfirmationPolicy.closePaneConfirmationBody(
                displayTitle: "Workspace",
                agentKind: .shell,
                riskReason: reason
            )
            #expect(body.contains("has activity"))
        }
        // Agent pane, but the risk isn't its live process — don't claim it is.
        #expect(
            DestructivePaneActionConfirmationPolicy.closePaneConfirmationBody(
                displayTitle: "Workspace",
                agentKind: .claudeCode,
                riskReason: .indeterminate
            ).contains("has activity")
        )
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
