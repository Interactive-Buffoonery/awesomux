import AwesoMuxConfig
import GhosttyKit
import Testing
@testable import awesoMux

@MainActor
@Suite("Generated Ghostty config overlays")
struct GhosttyGeneratedConfigOverlayParseTests {
    @Test("all generated overlays parse cleanly against linked libghostty")
    func generatedOverlaysParseCleanly() throws {
        GhosttyRuntime.initializeProcess()

        for overlay in Self.generatedOverlays {
            let config = try #require(ghostty_config_new())
            defer { ghostty_config_free(config) }

            let manager = GhosttyConfigManager(
                clipboardWritePolicy: .ask,
                confirmClipboardRead: true,
                copyOnSelect: .inherit,
                terminalAppearance: .defaultValue
            )

            #expect(manager.loadConfigContents(
                overlay.contents,
                into: config,
                filePrefix: overlay.filePrefix,
                failureMode: .failRuntime
            ), "Expected \(overlay.name) to parse cleanly")
            #expect(
                ghostty_config_diagnostics_count(config) == 0,
                "Expected \(overlay.name) to produce no libghostty diagnostics"
            )
        }
    }

    private static var generatedOverlays: [(name: String, filePrefix: String, contents: String)] {
        var overlays = [
            (
                name: "runtime defaults",
                filePrefix: "test-awesomux-defaults",
                contents: GhosttyRuntimeDefaults.defaultConfigContents
            )
        ]

        for clipboardWritePolicy in TerminalConfig.ClipboardWritePolicy.allCases {
            for confirmClipboardRead in [true, false] {
                for copyOnSelect in TerminalConfig.CopyOnSelect.allCases {
                    let terminalConfig = TerminalConfig(
                        clipboardWritePolicy: clipboardWritePolicy,
                        confirmClipboardRead: confirmClipboardRead,
                        copyOnSelect: copyOnSelect
                    )
                    overlays.append((
                        name: "terminal \(clipboardWritePolicy.rawValue) read=\(confirmClipboardRead) copy=\(copyOnSelect.rawValue)",
                        filePrefix: "test-awesomux-terminal",
                        contents: terminalConfig.ghosttyOverrideConfigContents
                    ))
                }
            }
        }

        for appearance in terminalAppearances {
            overlays.append((
                name: appearance.name,
                filePrefix: "test-awesomux-appearance",
                contents: appearance.preferences.ghosttyOverrideConfigContents
            ))
        }

        return overlays
    }

    private static var terminalAppearances: [(name: String, preferences: TerminalAppearancePreferences)] {
        [
            (
                name: "appearance default",
                preferences: .defaultValue
            ),
            (
                name: "appearance ghostty-owned dark",
                preferences: TerminalAppearancePreferences(
                    terminalBackgroundMode: .ghostty,
                    effectiveTheme: .dark
                )
            ),
            (
                name: "appearance ghostty-owned light",
                preferences: TerminalAppearancePreferences(
                    terminalBackgroundMode: .ghostty,
                    effectiveTheme: .light
                )
            ),
            (
                name: "appearance catppuccin dark",
                preferences: TerminalAppearancePreferences(
                    terminalBackgroundMode: .catppuccinTheme,
                    effectiveTheme: .dark
                )
            ),
            (
                name: "appearance catppuccin light",
                preferences: TerminalAppearancePreferences(
                    terminalBackgroundMode: .catppuccinTheme,
                    effectiveTheme: .light
                )
            ),
            (
                name: "appearance custom dark",
                preferences: TerminalAppearancePreferences(
                    terminalBackgroundMode: .custom,
                    terminalBackgroundColor: "#102030"
                )
            ),
            (
                name: "appearance custom light",
                preferences: TerminalAppearancePreferences(
                    terminalBackgroundMode: .custom,
                    terminalBackgroundColor: "#eff1f5"
                )
            ),
            (
                name: "appearance system font sentinel",
                preferences: TerminalAppearancePreferences(
                    monoFont: TerminalAppearancePreferences.systemMonospaceFont,
                    terminalBackgroundMode: .ghostty
                )
            ),
            (
                name: "appearance escaped font family",
                preferences: TerminalAppearancePreferences(
                    monoFont: #"Fancy "Mono" \ Nerd"#,
                    terminalBackgroundMode: .ghostty
                )
            )
        ]
    }
}
