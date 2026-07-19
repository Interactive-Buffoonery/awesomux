import Foundation
import Testing
@testable import AwesoMuxConfig

@Suite("AppearanceConfig.tintedHighContrast")
struct AppearanceConfigTintedHighContrastTests {
    private func decode(_ json: String) throws -> AppearanceConfig {
        try JSONDecoder().decode(AppearanceConfig.self, from: Data(json.utf8))
    }

    // A config written before this flag existed must load with the default
    // (false — neutral HC treatment), not throw — same forward-compat
    // contract as always_show_jump_numbers / crt_scanlines.
    @Test("absent key decodes to the default (false)")
    func absentKeyUsesDefault() throws {
        let json = """
            {"theme":"system","accent":"peach","ui_font":"system","mono_font":"m",
             "font_size":13,"glow_strength":0.65}
            """
        let config = try decode(json)
        #expect(config.tintedHighContrast == false)
    }

    @Test("present key is honored")
    func presentKeyHonored() throws {
        let json = """
            {"theme":"system","accent":"peach","ui_font":"system","mono_font":"m",
             "font_size":13,"glow_strength":0.65,"tinted_high_contrast":true}
            """
        let config = try decode(json)
        #expect(config.tintedHighContrast == true)
    }

    @Test("default value is false")
    func defaultValueIsFalse() {
        #expect(AppearanceConfig.defaultValue.tintedHighContrast == false)
    }
}
