import AwesoMuxBridgeProtocol
import AwesoMuxCore
import Foundation
import Testing

@testable import awesoMux

@MainActor
@Suite("Document nudge foreground gate")
struct DocumentNudgeForegroundGateTests {
    @Test("declared local pane rejects foreground SSH")
    func rejectsForegroundSSH() {
        let fixture = makeFixture(executionPlan: .local)

        #expect(resolve(fixture, comm: "ssh") == .unavailable(.foregroundSSH))
    }

    @Test("declared local pane rejects unknown foreground evidence")
    func rejectsUnknownForeground() {
        let fixture = makeFixture(executionPlan: .local)

        #expect(resolve(fixture, comm: nil) == .unavailable(.localTerminalUnverified))
    }

    @Test("a plain shell pane declines even when SSH evidence clears")
    func shellPaneDeclines() {
        let fixture = makeFixture(executionPlan: .local)

        #expect(resolve(fixture, comm: "ssh") == .unavailable(.foregroundSSH))
        #expect(resolve(fixture, comm: "zsh") == .unavailable(.noVerifiedAgent))
    }

    @Test("a waiting agent with live foreground evidence is available")
    func verifiedAgentIsAvailable() {
        let fixture = makeFixture(
            executionPlan: .local,
            agentKind: .codex,
            agentExecutionState: .waiting
        )

        #expect(resolve(fixture, comm: "codex") == .available(fixture.terminal))
    }

    @Test("a native-install Claude Code with a version-named binary is available")
    func nativeInstallClaudeIsAvailable() {
        let fixture = makeFixture(
            executionPlan: .local,
            agentKind: .claudeCode,
            agentExecutionState: .waiting
        )

        // The live maintainer repro: p_comm reads the resolved version-named
        // executable, not the `claude` symlink it was launched through.
        #expect(resolve(fixture, comm: "2.1.214") == .available(fixture.terminal))
    }

    @Test("a configured binary path verifies via its resolved basename")
    func configuredBinaryPathVerifies() {
        let fixture = makeFixture(
            executionPlan: .local,
            agentKind: .pi,
            agentExecutionState: .waiting
        )

        #expect(
            resolve(fixture, comm: "pi-custom", binaryPath: "/opt/agents/pi-custom")
                == .available(fixture.terminal)
        )
    }

    @Test("a same-provider relaunch's fresh generation declines until its own hook confirms it")
    func relaunchedProcessDeclines() {
        let fixture = makeFixture(
            executionPlan: .local,
            agentKind: .codex,
            agentExecutionState: .waiting
        )

        #expect(
            resolve(
                fixture,
                comm: "codex",
                verifiedGeneration: AgentForegroundIncarnation(pid: 100, startedAt: 1_000),
                observedGeneration: AgentForegroundIncarnation(pid: 200, startedAt: 2_000)
            ) == .unavailable(.noVerifiedAgent)
        )
    }

    @Test("no trusted hook generation on record declines a synthesized waiting state")
    func noTrustedGenerationDeclines() {
        let fixture = makeFixture(
            executionPlan: .local,
            agentKind: .codex,
            agentExecutionState: .waiting
        )

        #expect(
            resolve(
                fixture,
                comm: "codex",
                verifiedGeneration: nil,
                observedGeneration: AgentForegroundIncarnation(pid: 200, startedAt: 2_000)
            ) == .unavailable(.noVerifiedAgent)
        )
    }

    @Test("a waiting agent whose foreground process is not the provider declines")
    func staleAgentForegroundDeclines() {
        let fixture = makeFixture(
            executionPlan: .local,
            agentKind: .codex,
            agentExecutionState: .waiting
        )

        #expect(resolve(fixture, comm: "vim") == .unavailable(.noVerifiedAgent))
    }

    @Test("a running agent declines with its identity in the reason")
    func runningAgentDeclines() {
        let fixture = makeFixture(
            executionPlan: .local,
            agentKind: .claudeCode,
            agentExecutionState: .running
        )

        #expect(
            resolve(fixture, comm: "claude")
                == .unavailable(.agentNotReceptive(.claudeCode))
        )
    }

    @Test("a consent-gated provider with its integration disabled declines")
    func disabledIntegrationDeclines() {
        let fixture = makeFixture(
            executionPlan: .local,
            agentKind: .pi,
            agentExecutionState: .waiting
        )

        let resolution = DocumentPaneSendBar.resolveNudgeTarget(
            in: fixture.layout,
            for: fixture.document.id,
            isIntegrationEnabled: { _ in false }
        ) { _ in "pi" }

        #expect(resolution == .unavailable(.agentIntegrationDisabled(.pi)))
    }

    @Test("declared remote pane is rejected without consulting local process evidence")
    func declaredRemoteShortCircuitsProbe() {
        let target = RemoteTarget(user: "alice", host: "remote.example")!
        let fixture = makeFixture(executionPlan: .ssh(SSHExecution(target: target)))

        let resolution = DocumentPaneSendBar.resolveNudgeTarget(
            in: fixture.layout,
            for: fixture.document.id,
            isIntegrationEnabled: { _ in
                Issue.record("declared remote panes must not consult integration settings")
                return true
            }
        ) { _ in
            Issue.record("declared remote panes must not consult local process evidence")
            return "zsh"
        }

        #expect(resolution == .unavailable(.requiresLocalTerminal))
    }

    @Test("a document with no sibling terminal is unavailable")
    func noSiblingTerminalDeclines() {
        let document = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/a.md"),
            title: "a.md"
        )
        let group = DocumentGroup(tabs: [document], selectedTabID: document.id)
        let layout = TerminalPaneLayout.documentGroup(group)

        let resolution = DocumentPaneSendBar.resolveNudgeTarget(
            in: layout,
            for: document.id,
            isIntegrationEnabled: { _ in true }
        ) { _ in "zsh" }

        #expect(resolution == .unavailable(.terminalUnavailable))
    }

    @Test("multiple candidate sibling terminals decline rather than guess")
    func multipleSiblingsDecline() {
        let terminalA = TerminalPane(
            title: "a", workingDirectory: "/tmp", executionPlan: .local
        )
        let terminalB = TerminalPane(
            title: "b", workingDirectory: "/tmp", executionPlan: .local
        )
        let document = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/a.md"),
            title: "a.md"
        )
        let group = DocumentGroup(tabs: [document], selectedTabID: document.id)
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical,
                first: .documentGroup(group),
                second: .split(
                    TerminalSplit(
                        orientation: .horizontal,
                        first: .pane(terminalA),
                        second: .pane(terminalB)
                    )
                )
            )
        )

        let resolution = DocumentPaneSendBar.resolveNudgeTarget(
            in: layout,
            for: document.id,
            isIntegrationEnabled: { _ in true }
        ) { _ in "zsh" }

        #expect(resolution == .unavailable(.terminalUnavailable))
    }

    @Test("command-finished shell activity invalidates a disabled send bar")
    func commandFinishedInvalidatesSendBar() {
        let fixture = makeFixture(executionPlan: .local, shellActivity: .busy)
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [fixture.session])
        ])
        let busyID = DocumentNudgeSendBarID(
            documentID: fixture.document.id,
            target: fixture.terminal
        )
        let start = Date()
        let idle = ShellActivitySnapshot(
            sessionID: fixture.session.id,
            paneID: fixture.terminal.id,
            isBusy: false
        )

        _ = store.updateShellActivity([idle], now: start)
        _ = store.updateShellActivity([idle], now: start.addingTimeInterval(0.11))

        let target = store.session(id: fixture.session.id)?.layout
            .documentSendTarget(for: fixture.document.id)
        #expect(target?.shellActivity == .idle)
        #expect(
            DocumentNudgeSendBarID(
                documentID: fixture.document.id,
                target: target
            ) != busyID
        )
    }

    @Test("an agent state flip invalidates the send bar identity")
    func agentStateFlipInvalidatesSendBar() {
        let runningFixture = makeFixture(
            executionPlan: .local,
            agentKind: .claudeCode,
            agentExecutionState: .running
        )
        let runningID = DocumentNudgeSendBarID(
            documentID: runningFixture.document.id,
            target: runningFixture.terminal
        )

        var waitingTerminal = runningFixture.terminal
        waitingTerminal.agentExecutionState = .waiting

        #expect(
            DocumentNudgeSendBarID(
                documentID: runningFixture.document.id,
                target: waitingTerminal
            ) != runningID
        )
    }

    @Test("agent-specific denials still name the detected agent in the button title")
    func agentSpecificDenialsNameTheAgent() {
        #expect(
            DocumentPaneSendBar.sendButtonTitle(
                for: .unavailable(.agentNotReceptive(.claudeCode))
            ) == "Send to Claude"
        )
        #expect(
            DocumentPaneSendBar.sendButtonTitle(
                for: .unavailable(.agentIntegrationDisabled(.pi))
            ) == "Send to Pi"
        )
    }

    @Test("anonymous denials and verified targets title as before")
    func titleBaseline() {
        let fixture = makeFixture(
            executionPlan: .local,
            agentKind: .codex,
            agentExecutionState: .waiting
        )
        #expect(
            DocumentPaneSendBar.sendButtonTitle(for: .available(fixture.terminal))
                == "Send to Codex"
        )
        #expect(
            DocumentPaneSendBar.sendButtonTitle(for: .unavailable(.noVerifiedAgent))
                == "Send to Agent"
        )
        #expect(
            DocumentPaneSendBar.sendButtonTitle(for: .unavailable(.terminalUnavailable))
                == "Send to Agent"
        )
    }

    /// Matching by default: these fixtures test the SSH/comm/consent/receptive
    /// checks, not the generation-binding check added in the INT-569
    /// follow-up, so a same, non-nil incarnation on both sides keeps every
    /// pre-existing expectation exercising exactly what it names.
    private static let defaultGeneration = AgentForegroundIncarnation(pid: 4242, startedAt: 1_000)

    private func resolve(
        _ fixture: Fixture,
        comm: String?,
        binaryPath: String? = nil,
        verifiedGeneration: AgentForegroundIncarnation? = defaultGeneration,
        observedGeneration: AgentForegroundIncarnation? = defaultGeneration
    ) -> DocumentNudgeTargetResolution {
        DocumentPaneSendBar.resolveNudgeTarget(
            in: fixture.layout,
            for: fixture.document.id,
            isIntegrationEnabled: { _ in true },
            agentBinaryPath: { _ in binaryPath },
            foregroundComm: { paneID in
                #expect(paneID == fixture.terminal.id)
                return comm
            },
            foregroundGeneration: { _ in observedGeneration },
            verifiedWaitingForegroundGeneration: { _ in verifiedGeneration }
        )
    }

    private func makeFixture(
        executionPlan: PaneExecutionPlan,
        shellActivity: ShellActivity = .idle,
        agentKind: AgentKind = .shell,
        agentExecutionState: AgentExecutionState? = nil
    ) -> Fixture {
        let terminal = TerminalPane(
            title: "terminal",
            workingDirectory: "/tmp",
            agentKind: agentKind,
            agentExecutionState: agentExecutionState,
            shellActivity: shellActivity,
            executionPlan: executionPlan
        )
        let document = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/a.md"),
            title: "a.md",
            associatedTerminalPaneID: terminal.id
        )
        let group = DocumentGroup(tabs: [document], selectedTabID: document.id)
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical,
                first: .pane(terminal),
                second: .documentGroup(group)
            )
        )
        let session = TerminalSession(
            title: "test",
            workingDirectory: "/tmp",
            layout: layout,
            activePaneID: terminal.id
        )
        return Fixture(
            terminal: terminal,
            document: document,
            layout: layout,
            session: session
        )
    }

    private struct Fixture {
        let terminal: TerminalPane
        let document: DocumentPane
        let layout: TerminalPaneLayout
        let session: TerminalSession
    }
}
