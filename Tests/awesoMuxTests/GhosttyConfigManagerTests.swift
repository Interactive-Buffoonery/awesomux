import GhosttyKit
import Testing
@testable import awesoMux
import AwesoMuxConfig

@Suite("GhosttyConfigManager overlay failure resolution")
struct GhosttyConfigManagerOverlayTests {
    @MainActor
    @Test("configuration diagnostics report an invalid key")
    func configurationDiagnosticsCopy() throws {
        GhosttyRuntime.initializeProcess()
        let config = try #require(ghostty_config_new())
        let manager = GhosttyConfigManager(
            clipboardWritePolicy: .ask, confirmClipboardRead: true,
            copyOnSelect: .inherit, terminalAppearance: .defaultValue
        )
        #expect(
            manager.loadConfigContents(
                "not-a-real-ghostty-key = true\nbackground = #123456\n", into: config,
                filePrefix: "test-user-diagnostics", failureMode: .logWarning
            ))
        ghostty_config_finalize(config)
        let diagnostics = GhosttyConfigManager.diagnostics(from: config)
        ghostty_config_free(config)
        #expect(diagnostics.contains { $0.contains("not-a-real-ghostty-key") })
    }
}
