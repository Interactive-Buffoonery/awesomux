import Testing
import Foundation
@testable import AwesoMuxCore

@Suite("TerminalPane agent state")
struct TerminalPaneAgentStateTests {
    @Test("A fresh agent pane seeds its execution state from the kind")
    func seedsInitialStateFromKind() {
        let codex = TerminalPane(title: "t", workingDirectory: "~", agentKind: .codex, executionPlan: .local)
        #expect(codex.agentExecutionState == .running)

        let shell = TerminalPane(title: "t", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        #expect(shell.agentExecutionState == .idle)
    }

    @Test("agentState folds execution + attention like the session projection did")
    func agentStateProjection() {
        var pane = TerminalPane(title: "t", workingDirectory: "~", agentKind: .codex, executionPlan: .local)
        pane.agentExecutionState = .thinking
        #expect(pane.agentState == .thinking)

        pane.attentionReason = .permissionPrompt
        #expect(pane.agentState == .needsAttention)
    }

    @Test("effectiveChromeState collapses idle shells, keeps explicit attention")
    func effectiveChromeStateForShell() {
        var shell = TerminalPane(title: "t", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        shell.agentExecutionState = .running
        shell.shellActivity = .idle
        #expect(shell.effectiveChromeState == .idle)

        shell.shellActivity = .busy
        #expect(shell.effectiveChromeState == .running)

        shell.shellActivity = .idle
        shell.attentionReason = .bell
        #expect(shell.effectiveChromeState == .needsAttention)
    }

    @Test("effectiveChromeState collapses a stale shell .done at an idle prompt")
    func effectiveChromeStateCollapsesStaleShellDone() {
        var shell = TerminalPane(title: "t", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        shell.agentExecutionState = .done

        shell.shellActivity = .idle
        #expect(shell.effectiveChromeState == .idle)

        shell.shellActivity = .busy
        #expect(shell.effectiveChromeState == .idle)

        shell.agentExecutionState = .error
        shell.shellActivity = .idle
        #expect(shell.effectiveChromeState == .error)
    }

    @Test("quit risk: running agent pane is at risk until it ages out")
    func quitRiskAgesOut() {
        let now = Date()
        var pane = TerminalPane(title: "t", workingDirectory: "~", agentKind: .codex, executionPlan: .local)
        pane.agentExecutionState = .running
        pane.lastAgentStateChangeAt = now
        #expect(pane.isQuitRisk(at: now) == true)

        let stale = now.addingTimeInterval(TerminalPane.staleAgentActivityThreshold + 1)
        #expect(pane.isQuitRisk(at: stale) == false)
    }

    @Test("quit risk: idle shell at a prompt is safe, away from prompt is risky")
    func quitRiskShell() {
        var shell = TerminalPane(title: "t", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        #expect(shell.isQuitRisk() == false)

        shell.needsTerminalQuitConfirmation = true
        shell.terminalPromptObserved = true
        #expect(shell.isQuitRisk() == true)
    }

    @Test("the four durable agent fields round-trip through Codable; runtime fields reset")
    func codableRoundTrip() throws {
        var pane = TerminalPane(title: "t", workingDirectory: "~", agentKind: .codex, executionPlan: .local)
        pane.agentExecutionState = .thinking
        pane.attentionReason = .permissionPrompt
        pane.unreadNotificationCount = 3
        pane.shellActivity = .busy
        pane.needsTerminalQuitConfirmation = true

        let data = try JSONEncoder().encode(pane)
        let decoded = try JSONDecoder().decode(TerminalPane.self, from: data)

        #expect(decoded.agentKind == .codex)
        #expect(decoded.agentExecutionState == .thinking)
        #expect(decoded.attentionReason == .permissionPrompt)
        #expect(decoded.unreadNotificationCount == 3)
        // Runtime-only fields are intentionally not persisted.
        #expect(decoded.shellActivity == .idle)
        #expect(decoded.needsTerminalQuitConfirmation == false)
        #expect(decoded.terminalPromptObserved == false)
    }

    @Test("a legacy pane with no agent keys decodes as an idle shell")
    func legacyPaneDecodesAsIdleShell() throws {
        let legacy = """
        { "id": "\(UUID().uuidString)", "title": "t", "workingDirectory": "~" }
        """
        let decoded = try JSONDecoder().decode(TerminalPane.self, from: Data(legacy.utf8))
        #expect(decoded.agentKind == .shell)
        #expect(decoded.agentExecutionState == .idle)
        #expect(decoded.attentionReason == nil)
        #expect(decoded.unreadNotificationCount == 0)
    }
}
