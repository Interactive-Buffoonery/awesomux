import Foundation
import Testing
@testable import AwesoMuxConfig

@Suite("TerminalAppearancePreferences")
struct TerminalAppearancePreferencesTests {
    @Test("default terminal appearance uses bundled Hack Nerd Font Mono")
    func defaultTerminalAppearanceUsesBundledHackNerdFontMono() {
        #expect(AppearanceConfig.defaultValue.monoFont == TerminalAppearancePreferences.bundledMonoFont)
        #expect(TerminalAppearancePreferences.defaultValue.monoFont == TerminalAppearancePreferences.bundledMonoFont)
        #expect(TerminalAppearancePreferences.defaultValue.ghosttyOverrideConfigContents.contains(
            #"font-family = "Hack Nerd Font Mono""#
        ))
    }

    @Test("appearance config maps terminal font family and size")
    func appearanceConfigMapsTerminalFontFamilyAndSize() {
        let appearance = AppearanceConfig(
            monoFont: "Hack Nerd Font Mono",
            fontSize: 15
        )

        let preferences = TerminalAppearancePreferences(appearance: appearance)

        #expect(preferences.monoFont == "Hack Nerd Font Mono")
        #expect(preferences.fontSize == 15)
        #expect(preferences.ghosttyFontSize == 15)
    }

    @Test("Ghostty override config resets all four family fields before applying selected mono font")
    func ghosttyOverrideConfigResetsPreviousFontFamilies() {
        let preferences = TerminalAppearancePreferences(
            monoFont: "Hack Nerd Font Mono",
            fontSize: 14
        )

        // Ghostty has independent repeatable lists for `font-family`,
        // `font-family-bold`, `font-family-italic`, and `font-family-bold-italic`.
        // Resetting only the regular family lets a user `~/.config/ghostty/config`
        // setting `font-family-bold = "JetBrains Mono"` survive and produce a
        // mixed-font terminal. Reset all four; Ghostty derives bold/italic from
        // the regular family when style-specific lists are empty.
        #expect(preferences.ghosttyOverrideConfigContents == """
        font-size = 14
        font-family = ""
        font-family-bold = ""
        font-family-italic = ""
        font-family-bold-italic = ""
        font-family = "Hack Nerd Font Mono"
        """)
    }

    @Test("Ghostty override config emits no font-family override for the system-monospace sentinel")
    func ghosttyOverrideConfigEmitsNoOverrideForSystemSentinel() {
        // Forcing a literal family for the sentinel (previously `SF Mono`)
        // would silently fail on installs where CoreText can't resolve that
        // name. Letting Ghostty fall through to its own resolver is strictly
        // more robust.
        let preferences = TerminalAppearancePreferences(
            monoFont: "system-monospace",
            fontSize: 13
        )

        #expect(preferences.ghosttyOverrideConfigContents == "font-size = 13")
        #expect(!preferences.ghosttyOverrideConfigContents.contains("font-family"))
    }

    @Test("Ghostty override config escapes quote and backslash in font family")
    func ghosttyOverrideConfigEscapesFontFamily() {
        let preferences = TerminalAppearancePreferences(
            monoFont: #"Fancy "Mono" \ Nerd"#,
            fontSize: 13
        )

        #expect(preferences.ghosttyOverrideConfigContents.contains(#"font-family = "Fancy \"Mono\" \\ Nerd""#))
    }

    @Test("Ghostty font size clamps unsafe values")
    func ghosttyFontSizeClampsUnsafeValues() {
        #expect(TerminalAppearancePreferences(fontSize: .nan).ghosttyFontSize == 13)
        #expect(TerminalAppearancePreferences(fontSize: 2).ghosttyFontSize == 6)
        #expect(TerminalAppearancePreferences(fontSize: 80).ghosttyFontSize == 72)
    }

    @Test("terminal color scheme follows the terminal identity theme")
    func terminalColorSchemeFollowsTerminalIdentityTheme() {
        let ghosttyLight = TerminalAppearancePreferences(
            terminalBackgroundMode: .ghostty,
            effectiveTheme: .light
        )
        let ghosttyDark = TerminalAppearancePreferences(
            terminalBackgroundMode: .ghostty,
            effectiveTheme: .dark
        )
        let customDarkBackground = TerminalAppearancePreferences(
            terminalBackgroundMode: .custom,
            terminalBackgroundColor: "#313244",
            effectiveTheme: .light
        )

        #expect(ghosttyLight.terminalColorScheme == .light)
        #expect(ghosttyDark.terminalColorScheme == .dark)
        #expect(customDarkBackground.terminalColorScheme == .dark)
        #expect(TerminalAppearancePreferences.defaultValue.terminalColorScheme == .dark)
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

    @Test("default Hack Nerd Font Mono override emits regular + 3 reset lines")
    func defaultOverrideContainsAllFourFamilyResets() {
        let contents = TerminalAppearancePreferences.defaultValue.ghosttyOverrideConfigContents
        #expect(contents.contains(#"font-family = """#))
        #expect(contents.contains(#"font-family-bold = """#))
        #expect(contents.contains(#"font-family-italic = """#))
        #expect(contents.contains(#"font-family-bold-italic = """#))
    }

    @Test("default Ghostty terminal background mode emits no background override")
    func defaultTerminalBackgroundModeEmitsNoBackgroundOverride() {
        #expect(!TerminalAppearancePreferences.defaultValue.ghosttyOverrideConfigContents.contains("background ="))
        #expect(!TerminalAppearancePreferences.defaultValue.ghosttyOverrideConfigContents.contains("foreground ="))
        #expect(!TerminalAppearancePreferences.defaultValue.ghosttyOverrideConfigContents.contains("palette ="))
    }

    @Test("Ghostty mode advertises dark and light terminal identity at spawn")
    func ghosttyModeAdvertisesTerminalIdentityAtSpawn() {
        let dark = TerminalAppearancePreferences(
            terminalBackgroundMode: .ghostty,
            effectiveTheme: .dark
        )
        let light = TerminalAppearancePreferences(
            terminalBackgroundMode: .ghostty,
            effectiveTheme: .light
        )

        #expect(dark.terminalSpawnEnvironment["COLORFGBG"] == "15;0")
        #expect(light.terminalSpawnEnvironment["COLORFGBG"] == "0;15")
        #expect(dark.terminalSpawnEnvironment["AWESOMUX"] == "1")
        #expect(dark.terminalSpawnEnvironment["COLORTERM"] == "truecolor")
        #expect(dark.terminalSpawnEnvironment["TERM"] == "xterm-ghostty")
        #expect(dark.terminalSpawnEnvironment["TERM_PROGRAM"] == "ghostty")
        // AWESOMUX appears in both `terminalSpawnEnvironment` (always "1") and
        // `inheritedTerminalContextKeys` (so a parent-supplied value gets
        // stripped before awesoMux's "1" is reapplied). Exclude it from the
        // strip-only assertion.
        for key in TerminalAppearancePreferences.inheritedTerminalContextKeys where key != "AWESOMUX" {
            #expect(dark.terminalSpawnEnvironment[key] == nil)
        }
    }

    @Test("spawn environment overrides terminal identity and inherited terminal context")
    func spawnEnvironmentOverridesTerminalIdentityAndInheritedTerminalContext() {
        let preferences = TerminalAppearancePreferences(
            terminalBackgroundMode: .custom,
            terminalBackgroundColor: "#eff1f5"
        )

        let merged = preferences.environmentForTerminalSpawn(merging: [
            "AWESOMUX_SESSION_ID": "session-1",
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
            "ZELLIJ": "1"
        ])

        #expect(merged["AWESOMUX_SESSION_ID"] == "session-1")
        #expect(merged["AWESOMUX"] == "1")
        #expect(merged["COLORFGBG"] == "0;15")
        #expect(merged["COLORTERM"] == "truecolor")
        #expect(merged["NO_COLOR"] == "1")
        #expect(merged["TERM"] == "xterm-ghostty")
        #expect(merged["TERM_PROGRAM"] == "ghostty")
        // AWESOMUX is asserted above as "1" — awesoMux strips an inherited
        // value, then reapplies its own identity. Other inherited keys must
        // be fully absent.
        for key in TerminalAppearancePreferences.inheritedTerminalContextKeys where key != "AWESOMUX" {
            #expect(merged[key] == nil)
        }
    }

    @Test("spawn environment preserves deliberately injected compact-terminal markers")
    func spawnEnvironmentPreservesCompactTerminalMarkers() {
        // Both markers are injected per surface (literal here because
        // AwesoMuxConfig does not depend on AwesoMuxCore). They must survive
        // this merge. Nested-launch hygiene belongs in the app-startup
        // sanitizer, not this per-surface merge.
        let merged = TerminalAppearancePreferences.defaultValue.environmentForTerminalSpawn(
            merging: [
                "AWESOMUX_COMPACT_TERMINAL": "1",
                "AWESOMUX_FLOATING_PANEL": "1"
            ]
        )
        #expect(merged["AWESOMUX_COMPACT_TERMINAL"] == "1")
        #expect(merged["AWESOMUX_FLOATING_PANEL"] == "1")
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
            "PATH": "/usr/bin"
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
            ["LANG": "C", "LC_ALL": "fr_FR.utf8"]      // unhyphenated form
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

    @Test("settings-backed launch preferences keep custom terminal identity")
    func settingsBackedLaunchPreferencesKeepCustomTerminalIdentity() {
        let appearance = AppearanceConfig(
            theme: .dark,
            terminalBackgroundMode: .custom,
            terminalBackgroundColor: "#313244"
        )

        let preferences = TerminalAppearancePreferences(
            appearance: appearance,
            effectiveTheme: .dark
        )

        #expect(preferences != TerminalAppearancePreferences.defaultValue)
        #expect(preferences.ghosttyOverrideConfigContents.contains("background = #313244"))
        #expect(preferences.terminalSpawnEnvironment["COLORFGBG"] == "15;0")
    }

    @Test("Catppuccin terminal background mode emits effective theme colors")
    func catppuccinTerminalBackgroundModeEmitsEffectiveThemeColors() {
        let dark = TerminalAppearancePreferences(
            terminalBackgroundMode: .catppuccinTheme,
            effectiveTheme: .dark
        )
        let light = TerminalAppearancePreferences(
            terminalBackgroundMode: .catppuccinTheme,
            effectiveTheme: .light
        )

        #expect(dark.ghosttyOverrideConfigContents.contains("background = #1e1e2e"))
        #expect(dark.ghosttyOverrideConfigContents.contains("foreground = #cdd6f4"))
        #expect(dark.ghosttyOverrideConfigContents.contains("palette = 15=#bac2de"))
        #expect(light.ghosttyOverrideConfigContents.contains("background = #eff1f5"))
        #expect(light.ghosttyOverrideConfigContents.contains("foreground = #4c4f69"))
        #expect(light.ghosttyOverrideConfigContents.contains("palette = 15=#bcc0cc"))
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
    @Test(
        "generated Ghostty config is byte-exact across the mode/theme matrix",
        arguments: [
            GhosttyConfigMatrixCase(
                mode: .ghostty, effectiveTheme: .dark, customHex: "#1e1e2e",
                expected: "font-size = 13"
            ),
            GhosttyConfigMatrixCase(
                mode: .ghostty, effectiveTheme: .light, customHex: "#eff1f5",
                expected: "font-size = 13"
            ),
            GhosttyConfigMatrixCase(
                mode: .catppuccinTheme, effectiveTheme: .dark, customHex: "#1e1e2e",
                expected: """
                font-size = 13
                \(mochaColorLines)
                background = #1e1e2e
                """
            ),
            GhosttyConfigMatrixCase(
                mode: .catppuccinTheme, effectiveTheme: .light, customHex: "#eff1f5",
                expected: """
                font-size = 13
                \(latteColorLines)
                faint-opacity = 0.95
                background = #eff1f5
                """
            ),
            GhosttyConfigMatrixCase(
                mode: .custom, effectiveTheme: .dark, customHex: "#11111b",
                expected: """
                font-size = 13
                \(mochaColorLines)
                background = #11111b
                """
            ),
            GhosttyConfigMatrixCase(
                mode: .custom, effectiveTheme: .dark, customHex: "#DCE0E8",
                expected: """
                font-size = 13
                \(latteColorLines)
                faint-opacity = 0.95
                background = #dce0e8
                """
            )
        ]
    )
    func generatedGhosttyConfigIsByteExactAcrossModeThemeMatrix(
        testCase: GhosttyConfigMatrixCase
    ) {
        let preferences = TerminalAppearancePreferences(
            monoFont: TerminalAppearancePreferences.systemMonospaceFont,
            terminalBackgroundMode: testCase.mode,
            terminalBackgroundColor: testCase.customHex,
            effectiveTheme: testCase.effectiveTheme
        )

        #expect(preferences.ghosttyOverrideConfigContents == testCase.expected)
    }

    @Test("Latte Catppuccin override emits faint-opacity mitigation")
    func latteCatppuccinOverrideEmitsFaintOpacityMitigation() {
        let preferences = TerminalAppearancePreferences(
            terminalBackgroundMode: .catppuccinTheme,
            effectiveTheme: .light
        )

        #expect(preferences.ghosttyOverrideConfigContents.contains("faint-opacity = 0.95"))
    }

    @Test("Mocha Catppuccin override does not emit faint-opacity")
    func mochaCatppuccinOverrideDoesNotEmitFaintOpacity() {
        let preferences = TerminalAppearancePreferences(
            terminalBackgroundMode: .catppuccinTheme,
            effectiveTheme: .dark
        )

        #expect(!preferences.ghosttyOverrideConfigContents.contains("faint-opacity"))
    }

    @Test("Ghostty-owned light mode does not emit faint-opacity")
    func ghosttyOwnedLightModeDoesNotEmitFaintOpacity() {
        let preferences = TerminalAppearancePreferences(
            terminalBackgroundMode: .ghostty,
            effectiveTheme: .light
        )

        #expect(!preferences.ghosttyOverrideConfigContents.contains("faint-opacity"))
    }

    @Test("custom terminal background mode emits selected background with matched colors")
    func customTerminalBackgroundModeEmitsSelectedBackgroundWithMatchedColors() {
        let preferences = TerminalAppearancePreferences(
            terminalBackgroundMode: .custom,
            terminalBackgroundColor: "#ABCDEF"
        )

        #expect(preferences.ghosttyOverrideConfigContents.contains("background = #abcdef"))
        #expect(preferences.ghosttyOverrideConfigContents.contains("foreground = #4c4f69"))
        #expect(preferences.ghosttyOverrideConfigContents.contains("palette = 15=#bcc0cc"))
    }

    @Test("custom light terminal background mode emits faint-opacity mitigation")
    func customLightTerminalBackgroundModeEmitsFaintOpacityMitigation() {
        let preferences = TerminalAppearancePreferences(
            terminalBackgroundMode: .custom,
            terminalBackgroundColor: "#eff1f5",
            effectiveTheme: .dark
        )

        #expect(preferences.ghosttyOverrideConfigContents.contains("faint-opacity = 0.95"))
    }

    @Test("Latte faint opacity preserves AA contrast for base-safe text colors")
    func latteFaintOpacityPreservesAAContrastForBaseSafeTextColors() throws {
        let preferences = TerminalAppearancePreferences(
            terminalBackgroundMode: .catppuccinTheme,
            effectiveTheme: .light
        )
        let colors = try Self.parseEmittedTerminalColors(from: preferences.ghosttyOverrideConfigContents)
        let samples = [
            ("foreground", colors.foreground),
            ("palette0", colors.palette0),
            ("palette1", colors.palette1)
        ]

        for (label, sample) in samples {
            let blended = Self.blend(sample, over: colors.background, opacity: colors.faintOpacity)
            let ratio = Self.contrastRatio(blended, colors.background)
            #expect(ratio >= 4.5, "\(label) contrast after faint opacity was \(ratio)")
        }
    }

    @Test("mid-gray background classifies as dark via WCAG luminance")
    func midGrayBackgroundClassifiesAsDark() {
        // #808080 sits at sRGB 0.5 per channel; the naive (non-gamma)
        // formula would call it light (L ≈ 0.502 > 0.5). True WCAG relative
        // luminance is ~0.216, well below the 0.5 threshold — dark.
        let preferences = TerminalAppearancePreferences(
            terminalBackgroundMode: .custom,
            terminalBackgroundColor: "#808080",
            effectiveTheme: .light
        )
        #expect(preferences.terminalColorScheme == .dark)
        #expect(preferences.terminalSpawnEnvironment["COLORFGBG"] == "15;0")
    }

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

    @Test("custom dark terminal background mode uses Mocha foreground and palette")
    func customDarkTerminalBackgroundModeUsesMochaColors() {
        let preferences = TerminalAppearancePreferences(
            terminalBackgroundMode: .custom,
            terminalBackgroundColor: "#313244",
            effectiveTheme: .light
        )

        #expect(preferences.ghosttyOverrideConfigContents.contains("background = #313244"))
        #expect(preferences.ghosttyOverrideConfigContents.contains("foreground = #cdd6f4"))
        #expect(preferences.ghosttyOverrideConfigContents.contains("palette = 15=#bac2de"))
        #expect(preferences.terminalColorScheme == .dark)
        #expect(preferences.terminalSpawnEnvironment["COLORFGBG"] == "15;0")
    }

    @Test("Catppuccin background presets are bg tokens only (no accent colors)")
    func catppuccinBackgroundPresetsAreBackgroundTokensOnly() {
        // Mauve (#cba6f7) and Peach (#fab387) are Catppuccin *accent*
        // tokens — picking either as a terminal background gives ~1.6:1
        // contrast against a typical foreground, which is a foot-gun the
        // preset grid shouldn't ship without a contrast warning UI.
        let hexes = TerminalAppearancePreferences.catppuccinBackgroundPresets.map { $0.hex }
        #expect(!hexes.contains("#cba6f7"))
        #expect(!hexes.contains("#fab387"))
    }

    @Test("font-family override rejects names containing C0/C1 control characters")
    func fontFamilyRejectsControlCharacters() {
        // BEL, tab, DEL, and C1 controls are never legitimate parts of a
        // font family name. Letting them pass through to libghostty's
        // config parser is unnecessary attack surface.
        let bel = TerminalAppearancePreferences(monoFont: "Hack\u{07}Mono", fontSize: 13)
        let tab = TerminalAppearancePreferences(monoFont: "Hack\tMono", fontSize: 13)
        let del = TerminalAppearancePreferences(monoFont: "Hack\u{7F}Mono", fontSize: 13)
        let c1  = TerminalAppearancePreferences(monoFont: "Hack\u{80}Mono", fontSize: 13)

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

    private struct RGB {
        var red: Double
        var green: Double
        var blue: Double
    }

    private struct EmittedTerminalColors {
        var background: RGB
        var foreground: RGB
        var palette0: RGB
        var palette1: RGB
        var faintOpacity: Double
    }

    private static func parseEmittedTerminalColors(
        from contents: String
    ) throws -> EmittedTerminalColors {
        let faintOpacityValue = try #require(Self.configValue("faint-opacity", in: contents))
        return try EmittedTerminalColors(
            background: #require(Self.rgb(from: Self.configValue("background", in: contents))),
            foreground: #require(Self.rgb(from: Self.configValue("foreground", in: contents))),
            palette0: #require(Self.rgb(from: Self.paletteValue(0, in: contents))),
            palette1: #require(Self.rgb(from: Self.paletteValue(1, in: contents))),
            faintOpacity: #require(Double(faintOpacityValue))
        )
    }

    private static func configValue(_ key: String, in contents: String) -> String? {
        for line in contents.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { part in
                part.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2, parts[0] == key else {
                continue
            }

            return parts[1]
        }

        return nil
    }

    private static func paletteValue(_ index: Int, in contents: String) -> String? {
        for line in contents.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { part in
                part.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2, parts[0] == "palette" else {
                continue
            }

            let paletteParts = parts[1].split(separator: "=", maxSplits: 1).map { part in
                part.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard paletteParts.count == 2, paletteParts[0] == "\(index)" else {
                continue
            }

            return paletteParts[1]
        }

        return nil
    }

    private static func rgb(from hex: String?) -> RGB? {
        guard let hex else { return nil }
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6,
              let value = UInt32(trimmed, radix: 16) else {
            return nil
        }

        return RGB(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    private static func blend(_ foreground: RGB, over background: RGB, opacity: Double) -> RGB {
        RGB(
            red: foreground.red * opacity + background.red * (1 - opacity),
            green: foreground.green * opacity + background.green * (1 - opacity),
            blue: foreground.blue * opacity + background.blue * (1 - opacity)
        )
    }

    private static func contrastRatio(_ first: RGB, _ second: RGB) -> Double {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        return (max(firstLuminance, secondLuminance) + 0.05)
            / (min(firstLuminance, secondLuminance) + 0.05)
    }

    private static func relativeLuminance(_ color: RGB) -> Double {
        0.2126 * linearizedSRGB(color.red)
            + 0.7152 * linearizedSRGB(color.green)
            + 0.0722 * linearizedSRGB(color.blue)
    }

    private static func linearizedSRGB(_ channel: Double) -> Double {
        channel <= 0.04045
            ? channel / 12.92
            : pow((channel + 0.055) / 1.055, 2.4)
    }
}
