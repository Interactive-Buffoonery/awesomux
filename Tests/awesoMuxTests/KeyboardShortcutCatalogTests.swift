import AppKit
import AwesoMuxConfig
import Carbon.HIToolbox
import SwiftUI
import Testing
@testable import awesoMux

@Suite("KeyboardShortcutCatalog")
struct KeyboardShortcutCatalogTests {
    @Test("reload configuration uses shift command comma and supports custom settings")
    func reloadConfigurationBinding() throws {
        let binding = KeyboardShortcutCatalog.reloadGhosttyConfiguration
        #expect(binding.key == ",")
        #expect(binding.modifiers == [.command, .shift])
        #expect(binding.spokenForm.contains("Comma"))
        let keyboard = KeyboardConfig(shortcuts: [
            binding.id: ShortcutBindingConfig(key: "y", modifiers: [.command, .control])
        ])
        let resolved = try #require(KeyboardShortcutCatalog.resolvedBinding(id: binding.id, keyboard: keyboard))
        #expect(resolved.displaySymbol == "⌃⌘Y")
        #expect(
            KeyboardShortcutCatalog.allBindings(keyboard: keyboard).contains {
                $0.id == binding.id && $0.displaySymbol == "⌃⌘Y"
            })
    }
}
