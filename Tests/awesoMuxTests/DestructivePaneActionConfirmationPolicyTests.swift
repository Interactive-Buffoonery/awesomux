import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxCore
import AwesoMuxTestSupport
import Testing
@testable import awesoMux

@Suite("DestructivePaneActionConfirmationPolicy")
struct DestructivePaneActionConfirmationPolicyTests {
    @Test("pane action confirmations preserve displayed-title provenance")
    func paneActionConfirmationsPreserveDisplayedTitleProvenance() throws {
        let path = "Sources/awesoMux/App/AwesoMuxApp.swift"
        let source = try SourceContract.source(at: path)
        let confirmation = try SourceContract.declarationBody(
            after: "private func confirmDestructivePaneActionIfNeeded(",
            in: source,
            path: path
        )
        let close = try SourceContract.declarationBody(
            after: "private func closeActivePane()",
            in: source,
            path: path
        )
        let restart = try SourceContract.declarationBody(
            after: "private func restartActiveShell()",
            in: source,
            path: path
        )

        #expect(confirmation.contains("sanitizedAlertTitle(displayedTitle)"))
        #expect(close.contains("displayedTitle: actionSession.title"))
        #expect(restart.contains("displayedTitle: actionSession.title"))
    }

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

    @Test("confirmationBody names verified agent when sampledComm matches agentKind")
    func confirmationBodyNamesVerifiedAgentWhenCommandMatches() {
        let closePaneBody = DestructivePaneActionConfirmationPolicy.confirmationBody(
            action: .closePane,
            displayTitle: "Workspace",
            agentKind: .claudeCode,
            sampledComm: "claude",
            riskReason: .liveAgentProcess,
            riskyPaneCount: 1
        )
        #expect(closePaneBody == "Claude Code is running in this pane. Closing the pane will stop it.")

        let restartShellBody = DestructivePaneActionConfirmationPolicy.confirmationBody(
            action: .restartShell,
            displayTitle: "Workspace",
            agentKind: .claudeCode,
            sampledComm: "claude",
            riskReason: .activeAgentExecution,
            riskyPaneCount: 1
        )
        #expect(restartShellBody == "Claude Code is running in this pane. Restarting the shell will stop it.")

        let closeWorkspaceBody = DestructivePaneActionConfirmationPolicy.confirmationBody(
            action: .closeWorkspace,
            displayTitle: "Workspace",
            agentKind: .claudeCode,
            sampledComm: "claude",
            riskReason: .liveAgentProcess,
            riskyPaneCount: 1
        )
        #expect(closeWorkspaceBody == "Claude Code is running in this workspace. Closing the workspace will stop it.")
    }

    @Test("confirmationBody suppresses agent name when sampledComm does not match agentKind")
    func confirmationBodySuppressesAgentNameWhenCommandMismatches() {
        let bodyMismatchedComm = DestructivePaneActionConfirmationPolicy.confirmationBody(
            action: .closePane,
            displayTitle: "Workspace",
            agentKind: .claudeCode,
            sampledComm: "top",
            riskReason: .liveAgentProcess,
            riskyPaneCount: 1
        )
        #expect(bodyMismatchedComm == "This pane has running activity. Closing the pane will stop it.")

        let bodyNilComm = DestructivePaneActionConfirmationPolicy.confirmationBody(
            action: .closePane,
            displayTitle: "Workspace",
            agentKind: .claudeCode,
            sampledComm: nil,
            riskReason: .liveAgentProcess,
            riskyPaneCount: 1
        )
        #expect(bodyNilComm == "This pane has running activity. Closing the pane will stop it.")
    }

    @Test("confirmationBody uses honest copy for indeterminate state across all actions")
    func confirmationBodyHonestCopyForIndeterminateState() {
        let closePaneIndeterminate = DestructivePaneActionConfirmationPolicy.confirmationBody(
            action: .closePane,
            displayTitle: "Workspace",
            agentKind: .claudeCode,
            sampledComm: "claude",
            riskReason: .indeterminate,
            riskyPaneCount: 1
        )
        #expect(closePaneIndeterminate == "awesoMux couldn’t verify whether this pane is busy. Closing it may stop a running process.")

        let restartShellIndeterminate = DestructivePaneActionConfirmationPolicy.confirmationBody(
            action: .restartShell,
            displayTitle: "Workspace",
            agentKind: .shell,
            sampledComm: nil,
            riskReason: .indeterminate,
            riskyPaneCount: 1
        )
        #expect(
            restartShellIndeterminate
                == "awesoMux couldn’t verify whether this pane is busy. Restarting the shell may stop a running process.")

        let closeWorkspaceIndeterminate = DestructivePaneActionConfirmationPolicy.confirmationBody(
            action: .closeWorkspace,
            displayTitle: "Workspace",
            agentKind: .shell,
            sampledComm: nil,
            riskReason: .indeterminate,
            riskyPaneCount: 1
        )
        #expect(
            closeWorkspaceIndeterminate
                == "awesoMux couldn’t verify whether this workspace has running activity. Closing it may stop running processes.")
    }

    @Test("confirmationBody handles single vs multi pane workspace close copy and restart shell copy")
    func confirmationBodyHandlesSingleVsMultiPaneWorkspaceAndRestartShell() {
        let multiPaneWorkspaceBody = DestructivePaneActionConfirmationPolicy.confirmationBody(
            action: .closeWorkspace,
            displayTitle: "Workspace",
            agentKind: .shell,
            sampledComm: "make",
            riskReason: .liveForegroundProcess,
            riskyPaneCount: 2
        )
        #expect(multiPaneWorkspaceBody == "This workspace has activity running in multiple panes. Closing the workspace will stop it.")

        let singlePaneWorkspaceBody = DestructivePaneActionConfirmationPolicy.confirmationBody(
            action: .closeWorkspace,
            displayTitle: "Workspace",
            agentKind: .shell,
            sampledComm: "make",
            riskReason: .liveForegroundProcess,
            riskyPaneCount: 1
        )
        #expect(singlePaneWorkspaceBody == "This workspace has running activity. Closing the workspace will stop it.")

        let restartShellBusy = DestructivePaneActionConfirmationPolicy.confirmationBody(
            action: .restartShell,
            displayTitle: "Workspace",
            agentKind: .shell,
            sampledComm: "make",
            riskReason: .liveForegroundProcess,
            riskyPaneCount: 1
        )
        #expect(restartShellBusy == "This pane has running activity. Restarting the shell will stop it.")

        let restartShellIdle = DestructivePaneActionConfirmationPolicy.confirmationBody(
            action: .restartShell,
            displayTitle: "My Tab",
            agentKind: .shell,
            sampledComm: nil,
            riskReason: nil,
            riskyPaneCount: 0
        )
        #expect(
            restartShellIdle == "Restarting the shell in My Tab ends the current session and starts a fresh one. Scrollback isn't kept.")
    }

    @Test("close-pane body names the live agent when that is the risk (#190)")
    func closePaneBodyNamesLiveAgent() {
        let body = DestructivePaneActionConfirmationPolicy.closePaneConfirmationBody(
            displayTitle: "Workspace",
            agentKind: .claudeCode,
            sampledComm: "claude",
            riskReason: .liveAgentProcess
        )
        #expect(body.contains("Claude Code"))
        #expect(body.contains("Closing the pane will stop it."))
        #expect(!body.contains("has activity"))
    }

    @Test("close-pane body stays generic for non-agent risks")
    func closePaneBodyGenericForOtherRisks() {
        for reason in [QuitRiskReason.liveForegroundProcess, .terminalAwayFromPrompt] {
            let body = DestructivePaneActionConfirmationPolicy.closePaneConfirmationBody(
                displayTitle: "Workspace",
                agentKind: .shell,
                riskReason: reason
            )
            #expect(body.contains("has running activity"))
        }
        // Indeterminate risk gives honest unverified copy
        let indeterminateBody = DestructivePaneActionConfirmationPolicy.closePaneConfirmationBody(
            displayTitle: "Workspace",
            agentKind: .shell,
            riskReason: .indeterminate
        )
        #expect(indeterminateBody.contains("couldn’t verify"))

        // Agent pane, but the risk isn't verified live process — don't claim it is.
        #expect(
            DestructivePaneActionConfirmationPolicy.closePaneConfirmationBody(
                displayTitle: "Workspace",
                agentKind: .claudeCode,
                sampledComm: "top",
                riskReason: .indeterminate
            ).contains("couldn’t verify")
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
