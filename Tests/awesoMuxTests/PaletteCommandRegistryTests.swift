import AwesoMuxConfig
import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite("Palette command registry")
struct PaletteCommandRegistryTests {
    @Test("configuration reload is callable without a workspace and follows the catalog")
    @MainActor
    func reloadConfigurationWithoutWorkspace() throws {
        var calls = 0
        let commands = PaletteCommandRegistry.commands(
            sessionStore: SessionStore(groups: []), availability: .init(),
            actions: .noop(reloadGhosttyConfiguration: { calls += 1 })
        )
        let command = try #require(PaletteCommandRegistry.command(id: "reloadGhosttyConfiguration", in: commands))
        #expect(command.isEnabled)
        #expect(command.selectionScope == .none)
        #expect(command.shortcut?.configValue == KeyboardShortcutCatalog.reloadGhosttyConfiguration.configValue)
        #expect(KeyboardShortcutCatalog.allBindings().contains { $0.id == command.id })
        command.run()
        #expect(calls == 1)
    }
}
