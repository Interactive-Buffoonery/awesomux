import Testing
@testable import AwesoMuxConfig

@Suite("TerminalDiagnostics")
struct TerminalDiagnosticsTests {
    @Test("diagnostics are opt-in only with exact environment value")
    func diagnosticsRequireExactOptIn() {
        #expect(TerminalDiagnosticsConfiguration.isEnabled(environment: [:]) == false)
        #expect(TerminalDiagnosticsConfiguration.isEnabled(environment: [
            "AWESOMUX_TERMINAL_DIAGNOSTICS": "0"
        ]) == false)
        #expect(TerminalDiagnosticsConfiguration.isEnabled(environment: [
            "AWESOMUX_TERMINAL_DIAGNOSTICS": "true"
        ]) == false)
        #expect(TerminalDiagnosticsConfiguration.isEnabled(environment: [
            "AWESOMUX_TERMINAL_DIAGNOSTICS": "1"
        ]) == true)
    }

    @Test("environment snapshot captures only terminal color keys")
    func environmentSnapshotCapturesOnlyTerminalColorKeys() {
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

        #expect(TerminalDiagnosticEnvironmentSnapshot.capturedKeys == [
            "TERM",
            "COLORTERM",
            "COLORFGBG",
            "NO_COLOR",
            "FORCE_COLOR",
            "TERM_PROGRAM",
            "TMUX",
            "TMUX_PANE",
            "ZELLIJ",
            "STY",
            "MOSHI_SESSION",
            "SSH_CONNECTION",
            "SSH_CLIENT",
            "SSH_TTY"
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

    @Test("FORCE_COLOR logs known values but redacts arbitrary content to presence")
    func forceColorLogsKnownValuesOnly() {
        let numeric = TerminalDiagnosticEnvironmentSnapshot(environment: [
            "FORCE_COLOR": "3"
        ])
        let arbitrary = TerminalDiagnosticEnvironmentSnapshot(environment: [
            "FORCE_COLOR": "very colorful please"
        ])

        #expect(numeric.forceColor == "3")
        #expect(arbitrary.forceColor == "set")
    }

    @Test("FORCE_COLOR distinguishes empty value from missing key")
    func forceColorDistinguishesEmptyFromUnset() {
        let empty = TerminalDiagnosticEnvironmentSnapshot(environment: [
            "FORCE_COLOR": ""
        ])
        let missing = TerminalDiagnosticEnvironmentSnapshot(environment: [:])

        #expect(empty.forceColor == "empty")
        #expect(missing.forceColor == "unset")
    }

    @Test("missing color keys are reported as unset, not empty")
    func missingKeysReportUnset() {
        let snapshot = TerminalDiagnosticEnvironmentSnapshot(environment: [:])

        #expect(snapshot.term == "unset")
        #expect(snapshot.colorTerm == "unset")
        #expect(snapshot.colorFGBG == "unset")
        #expect(snapshot.noColor == "unset")
        #expect(snapshot.forceColor == "unset")
        #expect(snapshot.termProgram == "unset")
        #expect(snapshot.tmux == "unset")
        #expect(snapshot.sshConnection == "unset")
        #expect(snapshot.logFields.contains("term=unset"))
    }

    @Test("appearance diagnostic summary marks Ghostty-owned colors")
    func appearanceDiagnosticSummaryMarksGhosttyOwnedColors() {
        let preferences = TerminalAppearancePreferences(
            terminalBackgroundMode: .ghostty,
            effectiveTheme: .dark
        )
        let summary = preferences.diagnosticSummary

        #expect(summary.backgroundMode == "ghostty")
        #expect(summary.effectiveTheme == "dark")
        #expect(summary.terminalColorScheme == "dark")
        #expect(summary.awesoMuxOwnsColors == false)
        #expect(summary.background == "ghostty-owned")
        #expect(summary.foreground == "ghostty-owned")
        #expect(summary.palette0 == "ghostty-owned")
        #expect(summary.palette15 == "ghostty-owned")
        #expect(summary.faintOpacity == "ghostty-default")
        #expect(summary.logFields.contains("faint_opacity=ghostty-default"))
    }

    @Test("appearance diagnostic summary reports awesoMux-owned dark colors")
    func appearanceDiagnosticSummaryReportsAwesoMuxOwnedDarkColors() {
        let preferences = TerminalAppearancePreferences(
            terminalBackgroundMode: .custom,
            terminalBackgroundColor: "#313244",
            effectiveTheme: .light
        )
        let summary = preferences.diagnosticSummary

        #expect(summary.backgroundMode == "custom")
        #expect(summary.effectiveTheme == "light")
        #expect(summary.terminalColorScheme == "dark")
        #expect(summary.awesoMuxOwnsColors == true)
        #expect(summary.background == "#313244")
        #expect(summary.foreground == "#cdd6f4")
        #expect(summary.palette0 == "#45475a")
        #expect(summary.palette15 == "#bac2de")
        #expect(summary.faintOpacity == "ghostty-default")
    }

    @Test("appearance diagnostic summary reports awesoMux-owned light faint opacity")
    func appearanceDiagnosticSummaryReportsAwesoMuxOwnedLightFaintOpacity() {
        let preferences = TerminalAppearancePreferences(
            terminalBackgroundMode: .catppuccinTheme,
            effectiveTheme: .light
        )
        let summary = preferences.diagnosticSummary

        #expect(summary.backgroundMode == "catppuccin_theme")
        #expect(summary.effectiveTheme == "light")
        #expect(summary.terminalColorScheme == "light")
        #expect(summary.awesoMuxOwnsColors == true)
        #expect(summary.background == "#eff1f5")
        #expect(summary.foreground == "#4c4f69")
        #expect(summary.palette0 == "#5c5f77")
        #expect(summary.palette15 == "#bcc0cc")
        #expect(summary.faintOpacity == "0.95")
        #expect(summary.logFields.contains("faint_opacity=0.95"))
    }
}
