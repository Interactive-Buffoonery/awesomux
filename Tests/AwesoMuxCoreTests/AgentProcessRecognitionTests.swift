import Testing
@testable import AwesoMuxCore

@Suite("AgentProcessRecognition")
struct AgentProcessRecognitionTests {
    @Test("recognizes supported foreground agent commands")
    func recognizesSupportedForegroundAgentCommands() {
        #expect(AgentProcessRecognition.agentKind(forCommand: "codex") == .codex)
        #expect(AgentProcessRecognition.agentKind(forCommand: "/opt/homebrew/bin/codex") == .codex)
        #expect(AgentProcessRecognition.agentKind(forCommand: "codex-arm64") == .codex)
        #expect(AgentProcessRecognition.agentKind(forCommand: "opencode") == .openCode)
        #expect(AgentProcessRecognition.agentKind(forCommand: "opencode-cli") == .openCode)
        #expect(AgentProcessRecognition.agentKind(forCommand: "grok") == .grok)
        #expect(AgentProcessRecognition.agentKind(forCommand: "/Users/example/.grok/bin/grok") == .grok)
        #expect(AgentProcessRecognition.agentKind(forCommand: "grok-arm64") == .grok)
    }

    @Test("rejects non-agent foreground commands")
    func rejectsNonAgentForegroundCommands() {
        #expect(AgentProcessRecognition.agentKind(forCommand: nil) == nil)
        #expect(AgentProcessRecognition.agentKind(forCommand: "zsh") == nil)
        #expect(AgentProcessRecognition.agentKind(forCommand: "node") == nil)
        #expect(AgentProcessRecognition.agentKind(forCommand: "my-codex-wrapper") == nil)
    }
}
