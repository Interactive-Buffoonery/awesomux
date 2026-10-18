import Testing
@testable import AwesoMuxConfig

@Suite("TerminalDiagnostics")
struct TerminalDiagnosticsTests {

    @Test("environment snapshot excludes private environment values")
    func environmentSnapshotExcludesPII() {
        let snapshot = TerminalDiagnosticEnvironmentSnapshot(environment: [
            "TERM": "xterm-ghostty",
            "COLORTERM": "truecolor",
            "COLORFGBG": "15;0",
            "TERM_PROGRAM": "awesoMux",
            "TMUX": "",
            "TMUX_PANE": "%1",
            "ZELLIJ": "",
            "STY": "",
            "MOSHI_SESSION": "",
            "SSH_CONNECTION": "",
            "SSH_CLIENT": "",
            "SSH_TTY": "",
            "AWESOMUX_AGENT_EVENT_FILE": "/Users/example/.private/event.jsonl",
            "HOME": "/Users/example"
        ])

        #expect(snapshot.logFields.contains("term=xterm-ghostty"))
        #expect(snapshot.logFields.contains("colorterm=truecolor"))
        #expect(snapshot.logFields.contains("colorfgbg=15;0"))
        #expect(snapshot.logFields.contains("term_program=awesoMux"))
        #expect(snapshot.tmux == "empty")
        #expect(snapshot.logFields.contains("tmux=empty"))
        #expect(snapshot.logFields.contains("tmux_pane=set"))
        #expect(snapshot.logFields.contains("zellij=empty"))
        #expect(snapshot.logFields.contains("ssh_connection=empty"))
        #expect(snapshot.logFields.contains("AWESOMUX_AGENT_EVENT_FILE") == false)
        #expect(snapshot.logFields.contains("/Users/") == false)
        #expect(snapshot.logFields.contains("alice") == false)
    }

    @Test("environment snapshot redacts path-like values and control characters")
    func environmentSnapshotRedactsUnsafeValues() {
        let snapshot = TerminalDiagnosticEnvironmentSnapshot(environment: [
            "TERM": "/Users/example/.terminfo/xterm-ghostty",
            "COLORTERM": "truecolor\nleak",
            "COLORFGBG": "15;0",
            "NO_COLOR": "please-disable",
            "FORCE_COLOR": "/tmp/secret",
            "TERM_PROGRAM": #"Bad\Program"#
        ])

        #expect(snapshot.term == "redacted")
        #expect(snapshot.colorTerm == "truecolor_leak")
        #expect(snapshot.noColor == "set")
        #expect(snapshot.forceColor == "redacted")
        #expect(snapshot.termProgram == "redacted")
        #expect(snapshot.logFields.contains("/tmp") == false)
        #expect(snapshot.logFields.contains("\n") == false)
    }

}
