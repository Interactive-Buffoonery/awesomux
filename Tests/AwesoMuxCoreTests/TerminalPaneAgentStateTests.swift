import Testing
import Foundation
@testable import AwesoMuxCore

@Suite("TerminalPane agent state")
struct TerminalPaneAgentStateTests {

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
