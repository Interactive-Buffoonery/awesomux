import Testing
@testable import AwesoMuxConfig

@Suite("GhosttyRuntimeDefaults")
struct GhosttyRuntimeDefaultsTests {
    @Test("defaults set a bounded scrollback without enabling SSH helpers")
    func defaultsSetBoundedScrollbackWithoutEnablingSSHHelpers() {
        #expect(GhosttyRuntimeDefaults.defaultConfigContents == """
        scrollback-limit = 5000000

        """)
        #expect(!GhosttyRuntimeDefaults.defaultConfigContents.contains("ssh-env"))
    }

    @Test("defaults end with a trailing newline for ghostty config parsing")
    func defaultsEndWithTrailingNewline() {
        #expect(GhosttyRuntimeDefaults.defaultConfigContents.hasSuffix("\n"))
    }
}
