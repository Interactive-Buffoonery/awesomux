import AwesoMuxBridgeProtocol
import Testing
@testable import AwesoMuxCore

@Suite("AgentProcessRecognition")
struct AgentProcessRecognitionTests {
    @Test(
        arguments: [
            ("codex.exe", .codex),
            ("/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.exe", .codex),
            ("opencode.exe", .openCode),
            ("grok.exe", .grok),
            ("hermes.exe", .hermes),
            ("CODEX.EXE", .codex),
            (nil, nil),
            ("zsh", nil),
            ("node", nil),
            ("my-codex-wrapper", nil),
            ("node.exe", nil),
            (".exe", nil),
            ("pip", nil),
            ("pianobar", nil),
            ("amplify", nil),
            ("rootlesskit", nil),
            ("cursorctl", nil),
            ("2.1.214", .claudeCode),
            ("hermes", .hermes),
            ("1", nil),
        ] as [(String?, AgentKind?)])
    func recognizesCommand(command: String?, expected: AgentKind?) {
        #expect(AgentProcessRecognition.agentKind(forCommand: command) == expected)
    }
}
