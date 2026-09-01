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
        #expect(AgentProcessRecognition.agentKind(forCommand: "pi") == .pi)
        #expect(AgentProcessRecognition.agentKind(forCommand: "/opt/homebrew/bin/pi") == .pi)
    }

    @Test("recognizes every generic coding-agent command")
    func recognizesGenericAgentCommands() {
        let commands = [
            "muse", "cursor-agent", "cursor", "windsurf", "aider", "droid", "amp",
            "qwen", "kimi", "kilo", "roo", "cline", "copilot", "gemini", "goose",
            "continue", "zed", "warp", "crush", "kiro", "codebuddy", "qoder",
            "agy", "shai", "tabnine", "openclaw", "trae", "augment", "codebuff",
        ]

        for command in commands {
            #expect(AgentProcessRecognition.agentKind(forCommand: command) == .generic)
        }
        #expect(AgentProcessRecognition.agentKind(forCommand: "muse-bin") == .generic)
        #expect(AgentProcessRecognition.agentKind(forCommand: "cursor-agent-arm64") == .generic)
    }

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
}
