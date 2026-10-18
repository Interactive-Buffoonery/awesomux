import Foundation
import Testing
@testable import AwesoMuxConfig

@Suite("GhosttyConfigEnvironment")
struct GhosttyConfigEnvironmentTests {

    @Test("logFields emits public-safe scalar values with no PII")
    func logFieldsContainsNoPII() {
        let env = GhosttyConfigEnvironment(
            defaultScrollbackLimitBytes: 5_000_000,
            userXDGConfigExists: true,
            userAppSupportConfigExists: false
        )

        let fields = env.logFields
        #expect(fields.contains("default_scrollback_limit_bytes=5000000"))
        #expect(fields.contains("user_xdg_config_exists=true"))
        #expect(fields.contains("user_app_support_config_exists=false"))
        #expect(fields.contains("/Users/") == false)
        #expect(fields.contains(NSUserName()) == false)
    }
}
