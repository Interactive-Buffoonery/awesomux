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

        #expect(resolve(fixture, returningSSH: .matching) == .unavailable(.foregroundSSH))
    }

    @Test("declared local pane rejects unknown foreground evidence")
    func rejectsUnknownForeground() {
        let fixture = makeFixture(executionPlan: .local)

        #expect(
            resolve(fixture, returningSSH: .unknown) == .unavailable(.localTerminalUnverified)
        )
    }

    @Test("a plain shell pane declines even when SSH evidence clears")
    func shellPaneDeclines() {
        let fixture = makeFixture(executionPlan: .local)

        #expect(resolve(fixture, returningSSH: .matching) == .unavailable(.foregroundSSH))
        #expect(resolve(fixture, returningSSH: .notMatching) == .unavailable(.noVerifiedAgent))
    }

    @Test("a waiting agent with live foreground evidence is available")
    func verifiedAgentIsAvailable() {
        let fixture = makeFixture(
            executionPlan: .local,
            agentKind: .codex,
            agentExecutionState: .waiting
        )

        let resolution = resolve(fixture, returningSSH: .notMatching, returningAgent: .matching)
        #expect(resolution == .available(fixture.terminal))
    }

    @Test("a waiting agent whose foreground process is not the provider declines")
    func staleAgentForegroundDeclines() {
        let fixture = makeFixture(
            executionPlan: .local,
            agentKind: .codex,
            agentExecutionState: .waiting
        )

        #expect(
            resolve(fixture, returningSSH: .notMatching, returningAgent: .notMatching)
                == .unavailable(.noVerifiedAgent)
        )
    }

    @Test("a waiting agent with unknown foreground evidence at the agent probe declines")
    func unknownAgentForegroundDeclines() {
        let fixture = makeFixture(
            executionPlan: .local,
            agentKind: .codex,
            agentExecutionState: .waiting
        )

        #expect(
            resolve(fixture, returningSSH: .notMatching, returningAgent: .unknown)
                == .unavailable(.noVerifiedAgent)
        )
    }

    @Test("a running agent declines with its identity in the reason")
    func runningAgentDeclines() {
        let fixture = makeFixture(
            executionPlan: .local,
            agentKind: .claudeCode,
            agentExecutionState: .running
        )

        #expect(
            resolve(fixture, returningSSH: .notMatching, returningAgent: .matching)
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
        ) { _, _ in .notMatching }

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
        ) { _, _ in
            Issue.record("declared remote panes must not consult local process evidence")
            return .notMatching
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
        ) { _, _ in .matching }

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
        ) { _, _ in .matching }

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

    private func resolve(
        _ fixture: Fixture,
        returningSSH sshMatch: ProcessLivenessProbe.ForegroundExecutableMatch,
        returningAgent agentMatch: ProcessLivenessProbe.ForegroundExecutableMatch = .notMatching
    ) -> DocumentNudgeTargetResolution {
        DocumentPaneSendBar.resolveNudgeTarget(
            in: fixture.layout,
            for: fixture.document.id,
            isIntegrationEnabled: { _ in true }
        ) { executable, paneID in
            #expect(paneID == fixture.terminal.id)
            return executable == "ssh" ? sshMatch : agentMatch
        }
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
