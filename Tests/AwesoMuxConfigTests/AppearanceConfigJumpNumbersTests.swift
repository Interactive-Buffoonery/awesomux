import Foundation
import Testing
@testable import AwesoMuxConfig

@Suite("AppearanceConfig.alwaysShowJumpNumbers")
struct AppearanceConfigJumpNumbersTests {
    private func decode(_ json: String) throws -> AppearanceConfig {
        try JSONDecoder().decode(AppearanceConfig.self, from: Data(json.utf8))
    }

    // A v1 config written before this flag existed must load with the
    // default (false), not throw — same forward-compat contract as
    // crt_scanlines / cursor_glow.
    @Test("absent key decodes to the default (false)")
    func absentKeyUsesDefault() throws {
        let json = """
        {"theme":"system","accent":"peach","ui_font":"system","mono_font":"m",
         "font_size":13,"glow_strength":0.65}
        """
        let config = try decode(json)
        #expect(config.alwaysShowJumpNumbers == false)
    }

    @Test("present key is honored")
    func presentKeyHonored() throws {
        let json = """
        {"theme":"system","accent":"peach","ui_font":"system","mono_font":"m",
         "font_size":13,"glow_strength":0.65,"always_show_jump_numbers":true}
        """
        let config = try decode(json)
        #expect(config.alwaysShowJumpNumbers == true)
    }

    @Test("default value is false")
    func defaultValueIsFalse() {
        #expect(AppearanceConfig.defaultValue.alwaysShowJumpNumbers == false)
    }
}
