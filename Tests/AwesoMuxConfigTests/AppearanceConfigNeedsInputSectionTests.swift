import Foundation
import Testing
@testable import AwesoMuxConfig

@Suite struct AppearanceConfigNeedsInputSectionTests {
    private func decode(_ json: String) throws -> AppearanceConfig {
        try JSONDecoder().decode(AppearanceConfig.self, from: Data(json.utf8))
    }

    @Test func defaultsToOff() {
        // Reordering the sidebar is opt-in; a fresh install must not surprise.
        #expect(AppearanceConfig.defaultValue.promoteWorkspacesNeedingInput == false)
        #expect(DefaultPromoteWorkspacesNeedingInput.defaultValue == false)
    }

    @Test func absentKeyDecodesToDefault() throws {
        let json = """
            {"theme":"system","accent":"peach","ui_font":"system","mono_font":"m",
             "font_size":13,"glow_strength":0.65}
            """
        let config = try decode(json)
        #expect(config.promoteWorkspacesNeedingInput == false)
    }

    @Test func presentKeyIsHonored() throws {
        let json = """
            {"theme":"system","accent":"peach","ui_font":"system","mono_font":"m",
             "font_size":13,"glow_strength":0.65,"promote_workspaces_needing_input":true}
            """
        let config = try decode(json)
        #expect(config.promoteWorkspacesNeedingInput == true)
    }

    @Test func keyIsOwnedSoHandWrittenValuesAreNotDuplicated() {
        // TOMLConfigCodec splices back unknown user-written lines using this set.
        // A key missing from it round-trips twice: once preserved raw, once
        // structurally. There is no repo-wide test asserting ownedTOMLKeys is
        // complete, so this is the only guard.
        #expect(AppearanceConfig.ownedTOMLKeys.contains("promote_workspaces_needing_input"))
    }
}
