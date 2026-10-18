import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Agent state")
struct AgentStateTests {
    @Test(arguments: [
        (AgentExecutionState.done, AttentionReason.bell, AgentDisplayState.done),
        (.error, .bell, .error),
        (.error, .processError, .error),
        (.done, .permissionPrompt, .needsAttention),
        (.error, .userInputRequired, .needsAttention),
    ])
    func displayState(execution: AgentExecutionState, attention: AttentionReason, expected: AgentDisplayState) {
        #expect(AgentDisplayState(executionState: execution, attentionReason: attention) == expected)
    }

    @Test(arguments: [
        ("agentState", "error", AgentExecutionState.error, nil, AgentState.error),
        ("agentState", "done", .done, nil, .done),
        ("agentState", "waiting", .waiting, nil, .waiting),
        ("agentState", "idle", .idle, nil, .idle),
        ("agentState", "thinking", .thinking, nil, .thinking),
        ("agentState", "finished", .done, nil, .done),
        ("agentExecutionState", "finished", .done, nil, .done),
        ("agentState", "needsAttention", .running, AttentionReason.unknown, .needsAttention),
    ])
    func legacySessionState(key: String, legacy: String, execution: AgentExecutionState, attention: AttentionReason?, display: AgentState)
        throws
    {
        let json = Data(
            """
            {
              "id": "\(UUID().uuidString)",
              "title": "agent",
              "workingDirectory": "~",
              "agentKind": "Claude Code",
              "\(key)": "\(legacy)",
              "unreadNotificationCount": 1
            }
            """.utf8
        )
        let session = try JSONDecoder().decode(TerminalSession.self, from: json)
        #expect(session.agentExecutionState == execution)
        #expect(session.attentionReason == attention)
        #expect(session.agentState == display)
    }
}
