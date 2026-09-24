import Testing
@testable import AwesoMuxCore

@Suite("AgentProcessRecognition")
struct AgentProcessRecognitionTests {

    @Test("recognizes npm-packaged .exe launchers")
    func recognizesExeLaunchers() {
        // The pane-identity layer runs BEFORE AgentPromptGate: a pane this
        // mapper leaves as `.shell` is refused at the gate's first guard, so
        // both must agree on what a provider binary is called.
        #expect(AgentProcessRecognition.agentKind(forCommand: "codex.exe") == .codex)
        #expect(
            AgentProcessRecognition.agentKind(
                forCommand: "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.exe") == .codex)
        #expect(AgentProcessRecognition.agentKind(forCommand: "opencode.exe") == .openCode)
        #expect(AgentProcessRecognition.agentKind(forCommand: "grok.exe") == .grok)
        #expect(AgentProcessRecognition.agentKind(forCommand: "hermes.exe") == .hermes)
        #expect(AgentProcessRecognition.agentKind(forCommand: "CODEX.EXE") == .codex)
    }

    @Test("rejects non-agent foreground commands")
    func rejectsNonAgentForegroundCommands() {
        #expect(AgentProcessRecognition.agentKind(forCommand: nil) == nil)
        #expect(AgentProcessRecognition.agentKind(forCommand: "zsh") == nil)
        #expect(AgentProcessRecognition.agentKind(forCommand: "node") == nil)
        #expect(AgentProcessRecognition.agentKind(forCommand: "my-codex-wrapper") == nil)
        #expect(AgentProcessRecognition.agentKind(forCommand: "node.exe") == nil)
        #expect(AgentProcessRecognition.agentKind(forCommand: ".exe") == nil)
        // Pi matches its exact basename only — near-miss commands stay shell.
        #expect(AgentProcessRecognition.agentKind(forCommand: "pip") == nil)
        #expect(AgentProcessRecognition.agentKind(forCommand: "pianobar") == nil)
        #expect(AgentProcessRecognition.agentKind(forCommand: "amplify") == nil)
        #expect(AgentProcessRecognition.agentKind(forCommand: "rootlesskit") == nil)
        #expect(AgentProcessRecognition.agentKind(forCommand: "cursorctl") == nil)
    }

    @Test("bare version names stay Claude-only and do not claim Hermes")
    func bareVersionNamesStayClaudeOnly() {
        #expect(AgentProcessRecognition.agentKind(forCommand: "2.1.214") == .claudeCode)
        #expect(AgentProcessRecognition.agentKind(forCommand: "hermes") == .hermes)
        #expect(AgentProcessRecognition.agentKind(forCommand: "1") == nil)
    }
}
