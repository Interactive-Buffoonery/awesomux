import Foundation
import Testing
@testable import AwesoMuxConfig

@Suite("TerminalAppearancePreferences")
struct TerminalAppearancePreferencesTests {

    @Test(arguments: [
        (#"Fancy "Mono" \ Nerd"#, #"font-family = "Fancy \"Mono\" \\ Nerd""#),
        ("Hack\nfont-size = 72", ""), ("Hack\u{07}Mono", ""),
        ("Hack\tMono", ""), ("Hack\u{7F}Mono", ""), ("Hack\u{80}Mono", ""),
    ])
    func fontFamilyCannotInjectConfig(font: String, expected: String) {
        let contents = TerminalAppearancePreferences(monoFont: font, fontSize: 13).ghosttyOverrideConfigContents
        if expected.isEmpty { #expect(contents == "font-size = 13") } else { #expect(contents.contains(expected)) }
    }

    @Test("spawn environment overrides terminal identity and inherited terminal context")
    func spawnEnvironmentOverridesTerminalIdentityAndInheritedTerminalContext() {
        let preferences = TerminalAppearancePreferences(
            terminalBackgroundMode: .custom,
            terminalBackgroundColor: "#eff1f5"
        )

        let merged = preferences.environmentForTerminalSpawn(merging: [
            "AWESOMUX_SESSION_ID": "session-1",
            "CLAUDE_CODE_CHILD_SESSION": "1",
            "AWESOMUX": "0",
            "COLORFGBG": "15;0",
            "COLORTERM": "24bit",
            "MOSHI_SESSION": "moshi",
            "NO_COLOR": "1",
            "SSH_CLIENT": "127.0.0.1 1 2",
            "SSH_CONNECTION": "127.0.0.1 1 127.0.0.1 2",
            "SSH_TTY": "/dev/ttys001",
            "STY": "screen",
            "TERM": "vt100",
            "TERM_PROGRAM": "Ghostty",
            "TMUX": "/tmp/tmux-501/default,1,0",
            "TMUX_PANE": "%1",
            "ZELLIJ": "1",
        ])

        #expect(merged["AWESOMUX_SESSION_ID"] == "session-1")
        #expect(merged["CLAUDE_CODE_CHILD_SESSION"] == nil)
        #expect(merged["AWESOMUX"] == "1")
        #expect(merged["COLORFGBG"] == "0;15")
        #expect(merged["COLORTERM"] == "truecolor")
        #expect(merged["NO_COLOR"] == "1")
        #expect(merged["TERM"] == "xterm-ghostty")
        #expect(merged["TERM_PROGRAM"] == "awesoMux")
        // AWESOMUX is asserted above as "1" — awesoMux strips an inherited
        // value, then reapplies its own identity. Other inherited keys must
        // be fully absent.
        for key in TerminalAppearancePreferences.inheritedTerminalContextKeys where key != "AWESOMUX" {
            #expect(merged[key] == nil)
        }
    }

    @Test("spawn environment strips inherited GHOSTTY_*/CMUX_* parent-terminal context")
    func spawnEnvironmentStripsGhosttyAndCmuxFamilies() {
        // When awesoMux is launched from inside another ghostty-based terminal
        // (Ghostty, cmux, or itself), the child inherits GHOSTTY_RESOURCES_DIR
        // etc. pointing at the PARENT's bundle. Leaving them set makes
        // libghostty load the wrong shell integration — no OSC 133 prompt
        // markers, so the quit-confirm gate fires on every shell. The whole
        // GHOSTTY_*/CMUX_* family must be dropped; libghostty re-establishes its
        // own values for our bundle during spawn.
        let merged = TerminalAppearancePreferences.defaultValue.environmentForTerminalSpawn(merging: [
            "GHOSTTY_RESOURCES_DIR": "/Applications/cmux.app/Contents/Resources/ghostty",
            "GHOSTTY_BIN_DIR": "/Applications/cmux.app/Contents/MacOS",
            "GHOSTTY_SHELL_FEATURES": "cursor,title",
            "GHOSTTY_SURFACE_ID": "42",
            "CMUX_SOCKET": "/tmp/cmux.sock",
            "CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION": "1",
            "PATH": "/usr/bin",
        ])

        #expect(merged["GHOSTTY_RESOURCES_DIR"] == nil)
        #expect(merged["GHOSTTY_BIN_DIR"] == nil)
        #expect(merged["GHOSTTY_SHELL_FEATURES"] == nil)
        #expect(merged["GHOSTTY_SURFACE_ID"] == nil)
        #expect(merged["CMUX_SOCKET"] == nil)
        #expect(merged["CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION"] == nil)
        // Unrelated vars pass through untouched.
        #expect(merged["PATH"] == "/usr/bin")
    }

    // MARK: - UTF-8 locale fallback (INT-140)

    @Test(arguments: [
        ([String: String](), [String: String](), ["LC_CTYPE": "UTF-8"]),
        (["LANG": "C"], [:], ["LC_CTYPE": "UTF-8"]),
        (["LANG": "POSIX"], [:], ["LC_CTYPE": "UTF-8"]),
        (["LANG": "c"], [:], ["LC_CTYPE": "UTF-8"]),
        (["LANG": "", "LC_CTYPE": ""], [:], ["LC_CTYPE": "UTF-8"]),
        (["LANG": "en_US.UTF-8"], [:], [:]),
        (["LC_CTYPE": "ja_JP.UTF-8"], [:], [:]),
        (["LC_ALL": "de_DE.UTF-8"], [:], [:]),
        (["LANG": "C", "LC_CTYPE": "en_GB.UTF-8"], [:], [:]),
        (["LANG": "C", "LC_ALL": "fr_FR.utf8"], [:], [:]),
        (["LC_ALL": "C", "LANG": "en_US.UTF-8"], [:], [:]),
        (["LANG": "", "LC_CTYPE": "C"], ["PATH": "/usr/bin"], ["LC_CTYPE": "UTF-8"]),
        (["LANG": "en_US.UTF-8"], ["PATH": "/usr/bin"], [:]),
        (["LANG": "C"], ["LC_CTYPE": "C"], ["LC_CTYPE": "UTF-8"]),
    ])
    func localeFallback(inherited: [String: String], merging: [String: String], expected: [String: String]) {
        #expect(TerminalAppearancePreferences.localeCtypeFallback(inheritedEnvironment: inherited) == expected)
        let merged = TerminalAppearancePreferences.defaultValue.environmentForTerminalSpawn(
            merging: merging, inheritedEnvironment: inherited
        )
        #expect(merged["LC_CTYPE"] == (merging["LC_CTYPE"] ?? expected["LC_CTYPE"]))
    }

}
