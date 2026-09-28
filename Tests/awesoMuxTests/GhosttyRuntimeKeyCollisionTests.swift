import AppKit
import AwesoMuxConfig
import Carbon.HIToolbox
import GhosttyKit
import SwiftUI
import Testing
@testable import awesoMux

@Suite("Menu/binding collision detection")
struct GhosttyRuntimeKeyCollisionTests {
    @MainActor
    @Test("only the expected reload action and chord bypass collision warnings")
    func expectedReloadBindingOnly() throws {
        try #require(GhosttyRuntime.initializeProcess())
        let manager = GhosttyConfigManager(
            clipboardWritePolicy: .ask, confirmClipboardRead: true,
            copyOnSelect: .inherit, terminalAppearance: .defaultValue
        )
        for (contents, expected) in [
            ("keybind = super+shift+,=reload_config\n", true),
            ("keybind = clear\nkeybind = super+shift+Comma=reload_config\n", true),
            ("keybind = clear\nkeybind = super+shift+,=reload_config\nkeybind = super+shift+Comma=new_tab\n", false),
            ("keybind = clear\nkeybind = super+shift+Comma=reload_config\nkeybind = super+shift+,=new_tab\n", false),
            ("keybind = super+shift+comma=new_tab\n", false),
            ("keybind = super+shift+,=new_tab\n", false),
        ] {
            let config = try #require(ghostty_config_new())
            defer { ghostty_config_free(config) }
            try #require(manager.loadConfigContents(contents, into: config, filePrefix: "test-reload-binding", failureMode: .failRuntime))
            ghostty_config_finalize(config)
            #expect(GhosttyRuntime.isExpectedReloadBinding(KeyboardShortcutCatalog.reloadGhosttyConfiguration, config: config) == expected)
            #expect(!GhosttyRuntime.isExpectedReloadBinding(KeyboardShortcutCatalog.newWorkspace, config: config))
            let rebound = KeyboardShortcutCatalog.reloadGhosttyConfiguration.applying(.init(key: "r", modifiers: [.command, .shift]))
            #expect(!GhosttyRuntime.isExpectedReloadBinding(rebound, config: config))
        }
    }
}
