import GhosttyKit
import Testing
@testable import awesoMux
import AwesoMuxConfig

@Suite("GhosttyConfigManager overlay failure resolution")
struct GhosttyConfigManagerOverlayTests {
    @MainActor
    @Test("configuration diagnostics are copied and valid settings survive invalid keys")
    func configurationDiagnosticsCopy() throws {
        GhosttyRuntime.initializeProcess()
        let config = try #require(ghostty_config_new())
        let manager = GhosttyConfigManager(
            clipboardWritePolicy: .ask, confirmClipboardRead: true,
            copyOnSelect: .inherit, terminalAppearance: .defaultValue
        )
        #expect(GhosttyConfigManager.diagnostics(from: config).isEmpty)
        #expect(
            manager.loadConfigContents(
                "not-a-real-ghostty-key = true\nbackground = #123456\n", into: config,
                filePrefix: "test-user-diagnostics", failureMode: .logWarning
            ))
        ghostty_config_finalize(config)
        let diagnostics = GhosttyConfigManager.diagnostics(from: config)
        var background = ghostty_config_color_s()
        let found = "background".withCString { ghostty_config_get(config, &background, $0, 10) }
        ghostty_config_free(config)
        #expect(diagnostics.contains { $0.contains("not-a-real-ghostty-key") })
        #expect(found)
        #expect(background.r == 0x12 && background.g == 0x34 && background.b == 0x56)
    }
}
