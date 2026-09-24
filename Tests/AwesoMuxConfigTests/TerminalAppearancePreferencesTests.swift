import Foundation
import Testing
@testable import AwesoMuxConfig

@Suite("TerminalAppearancePreferences")
struct TerminalAppearancePreferencesTests {

    @Test("Ghostty override config escapes quote and backslash in font family")
    func ghosttyOverrideConfigEscapesFontFamily() {
        let preferences = TerminalAppearancePreferences(
            monoFont: #"Fancy "Mono" \ Nerd"#,
            fontSize: 13
        )

        #expect(preferences.ghosttyOverrideConfigContents.contains(#"font-family = "Fancy \"Mono\" \\ Nerd""#))
    }

    @Test("Ghostty override config drops invalid font family text")
    func ghosttyOverrideConfigDropsInvalidFontFamilyText() {
        let preferences = TerminalAppearancePreferences(
            monoFont: "Hack\nfont-size = 72",
            fontSize: 13
        )

        // Positive equality so a future regression that emits the reset
        // lines without the value line can't pass this test by accident.
        #expect(preferences.ghosttyOverrideConfigContents == "font-size = 13")
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

    @Test("locale fallback injects UTF-8 ctype when no locale is inherited")
    func localeFallbackInjectsUTF8WhenNoLocaleInherited() {
        // The GUI/launchd launch path: awesoMux inherits no LANG/LC_*, so a
        // child shell would land in the C locale and echo typed emoji as
        // <0001f973> placeholders. The fallback gives it a UTF-8 ctype.
        let fallback = TerminalAppearancePreferences.localeCtypeFallback(
            inheritedEnvironment: [:]
        )
        #expect(fallback == ["LC_CTYPE": "UTF-8"])
    }

    @Test("locale fallback also fires when inherited locale is C/POSIX")
    func localeFallbackFiresForCAndPosixLocales() {
        for value in ["C", "POSIX", "c"] {
            #expect(
                TerminalAppearancePreferences.localeCtypeFallback(
                    inheritedEnvironment: ["LANG": value]
                ) == ["LC_CTYPE": "UTF-8"],
                "LANG=\(value) should get a UTF-8 ctype fallback"
            )
        }
        // Empty values are treated as unset, not as a valid locale.
        #expect(
            TerminalAppearancePreferences.localeCtypeFallback(
                inheritedEnvironment: ["LANG": "", "LC_CTYPE": ""]
            ) == ["LC_CTYPE": "UTF-8"]
        )
    }

    @Test("locale fallback is empty when a UTF-8 locale is already inherited")
    func localeFallbackEmptyWhenUTF8Inherited() {
        let utf8Environments: [[String: String]] = [
            ["LANG": "en_US.UTF-8"],
            ["LC_CTYPE": "ja_JP.UTF-8"],
            ["LC_ALL": "de_DE.UTF-8"],
            ["LANG": "C", "LC_CTYPE": "en_GB.UTF-8"],  // LC_CTYPE wins over LANG
            ["LANG": "C", "LC_ALL": "fr_FR.utf8"],  // unhyphenated form
        ]
        for environment in utf8Environments {
            #expect(
                TerminalAppearancePreferences.localeCtypeFallback(
                    inheritedEnvironment: environment
                ).isEmpty,
                "UTF-8 locale in \(environment) should suppress the fallback"
            )
        }
    }

    @Test("locale fallback respects an explicit non-UTF-8 LC_ALL")
    func localeFallbackRespectsExplicitLCAll() {
        // LC_ALL shadows LC_CTYPE in libc, so injecting LC_CTYPE=UTF-8 would be
        // inert — and an explicit LC_ALL=C is a deliberate choice we don't
        // fight. The fallback must stay out of the way.
        #expect(
            TerminalAppearancePreferences.localeCtypeFallback(
                inheritedEnvironment: ["LC_ALL": "C", "LANG": "en_US.UTF-8"]
            ).isEmpty
        )
    }

    @Test("spawn environment injects UTF-8 ctype for a C-locale launch")
    func spawnEnvironmentInjectsUTF8ForCLocaleLaunch() {
        let merged = TerminalAppearancePreferences.defaultValue.environmentForTerminalSpawn(
            merging: ["PATH": "/usr/bin"],
            inheritedEnvironment: ["LANG": "", "LC_CTYPE": "C"]
        )
        #expect(merged["LC_CTYPE"] == "UTF-8")
    }

    @Test("spawn environment leaves an inherited UTF-8 locale untouched")
    func spawnEnvironmentLeavesInheritedUTF8Untouched() {
        let merged = TerminalAppearancePreferences.defaultValue.environmentForTerminalSpawn(
            merging: ["PATH": "/usr/bin"],
            inheritedEnvironment: ["LANG": "en_US.UTF-8"]
        )
        // No LC_CTYPE override — the user's LANG already provides a UTF-8 ctype.
        #expect(merged["LC_CTYPE"] == nil)
    }

    @Test("spawn environment defers to an LC_CTYPE supplied in the merging dict")
    func spawnEnvironmentDefersToMergingDictLCCtype() {
        // The fallback is guarded by `where merged[key] == nil`, so a caller
        // that already pins LC_CTYPE wins even when the inherited locale is C.
        let merged = TerminalAppearancePreferences.defaultValue.environmentForTerminalSpawn(
            merging: ["LC_CTYPE": "C"],
            inheritedEnvironment: ["LANG": "C"]
        )
        #expect(merged["LC_CTYPE"] == "C")
    }

    struct GhosttyConfigMatrixCase: Sendable, CustomTestStringConvertible {
        let mode: AppearanceConfig.TerminalBackgroundMode
        let effectiveTheme: TerminalAppearancePreferences.EffectiveTheme
        // Only read in .custom mode; picks the luminance side that drives
        // the identity theme so the matrix covers custom-light and custom-dark.
        let customHex: String
        let expected: String

        var testDescription: String { "\(mode.rawValue) / \(effectiveTheme)" }
    }

    private static let mochaColorLines = """
        palette = 0=#45475a
        palette = 1=#f38ba8
        palette = 2=#a6e3a1
        palette = 3=#f9e2af
        palette = 4=#89b4fa
        palette = 5=#f5c2e7
        palette = 6=#94e2d5
        palette = 7=#a6adc8
        palette = 8=#585b70
        palette = 9=#f37799
        palette = 10=#89d88b
        palette = 11=#ebd391
        palette = 12=#74a8fc
        palette = 13=#f2aede
        palette = 14=#6bd7ca
        palette = 15=#bac2de
        foreground = #cdd6f4
        cursor-color = #f5e0dc
        cursor-text = #1e1e2e
        selection-background = #585b70
        selection-foreground = #cdd6f4
        """

    private static let latteColorLines = """
        palette = 0=#5c5f77
        palette = 1=#d20f39
        palette = 2=#40a02b
        palette = 3=#df8e1d
        palette = 4=#1e66f5
        palette = 5=#ea76cb
        palette = 6=#179299
        palette = 7=#acb0be
        palette = 8=#6c6f85
        palette = 9=#de293e
        palette = 10=#49af3d
        palette = 11=#eea02d
        palette = 12=#456eff
        palette = 13=#fe85d8
        palette = 14=#2d9fa8
        palette = 15=#bcc0cc
        foreground = #4c4f69
        cursor-color = #dc8a78
        cursor-text = #eff1f5
        selection-background = #acb0be
        selection-foreground = #4c4f69
        """

    // Byte-exact acceptance pin for INT-654: the provider refactor must
    // reproduce the pre-seam generated config for every mode x theme cell.

    @Test("custom mode with malformed background hex falls back to the default")
    func customMalformedBackgroundFallsBack() {
        let preferences = TerminalAppearancePreferences(
            terminalBackgroundMode: .custom,
            terminalBackgroundColor: "not-a-hex",
            effectiveTheme: .light
        )

        // Init-time normalize replaces the bad value with the configured
        // default (so the struct never carries a nonsense color), and the
        // re-normalize in `ghosttyBackgroundColor` returns the same default.
        let fallback = AppearanceConfig.defaultValue.terminalBackgroundColor
        #expect(preferences.terminalBackgroundColor == fallback)
        #expect(preferences.ghosttyBackgroundColor == fallback)
        // Must not crash — terminalColorScheme is consulted by spawn env,
        // override config emit, and runtime apply.
        _ = preferences.terminalColorScheme
    }

    @Test("font-family override rejects names containing C0/C1 control characters")
    func fontFamilyRejectsControlCharacters() {
        // BEL, tab, DEL, and C1 controls are never legitimate parts of a
        // font family name. Letting them pass through to libghostty's
        // config parser is unnecessary attack surface.
        let bel = TerminalAppearancePreferences(monoFont: "Hack\u{07}Mono", fontSize: 13)
        let tab = TerminalAppearancePreferences(monoFont: "Hack\tMono", fontSize: 13)
        let del = TerminalAppearancePreferences(monoFont: "Hack\u{7F}Mono", fontSize: 13)
        let c1 = TerminalAppearancePreferences(monoFont: "Hack\u{80}Mono", fontSize: 13)

        #expect(bel.ghosttyOverrideConfigContents == "font-size = 13")
        #expect(tab.ghosttyOverrideConfigContents == "font-size = 13")
        #expect(del.ghosttyOverrideConfigContents == "font-size = 13")
        #expect(c1.ghosttyOverrideConfigContents == "font-size = 13")
    }

    @Test("hex normalization boundary cases")
    func hexNormalizationBoundaryCases() {
        // Loud-fail forms.
        #expect(AppearanceConfig.normalizedTerminalBackgroundColor("") == nil)
        #expect(AppearanceConfig.normalizedTerminalBackgroundColor("#") == nil)
        #expect(AppearanceConfig.normalizedTerminalBackgroundColor("#abc") == nil)
        #expect(AppearanceConfig.normalizedTerminalBackgroundColor("#abcdefab") == nil)
        #expect(AppearanceConfig.normalizedTerminalBackgroundColor("abcdef") == nil)
        #expect(AppearanceConfig.normalizedTerminalBackgroundColor("#zzzzzz") == nil)
        // Whitespace-tolerant, case-folding.
        #expect(AppearanceConfig.normalizedTerminalBackgroundColor("  #1e1e2e  ") == "#1e1e2e")
        #expect(AppearanceConfig.normalizedTerminalBackgroundColor("#ABCDEF") == "#abcdef")
    }
}
