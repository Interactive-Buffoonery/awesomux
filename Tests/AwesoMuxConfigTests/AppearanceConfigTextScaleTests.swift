import Foundation
import Testing
@testable import AwesoMuxConfig

@Suite("AppearanceConfig.uiTextScale")
struct AppearanceConfigTextScaleTests {
    private func decode(_ json: String) throws -> AppearanceConfig {
        try JSONDecoder().decode(AppearanceConfig.self, from: Data(json.utf8))
    }

    // A config written before INT-237 (no ui_text_scale key) must load with the
    // default (1.0), not throw — same forward-compat contract as the other
    // late-added appearance keys.
    @Test("absent key decodes to the default (1.0)")
    func absentKeyUsesDefault() throws {
        let json = """
        {"theme":"system","accent":"peach","ui_font":"system","mono_font":"m",
         "font_size":13,"glow_strength":0.65}
        """
        let config = try decode(json)
        #expect(config.uiTextScale == 1.0)
    }

    @Test("present key is honored")
    func presentKeyHonored() throws {
        let json = """
        {"theme":"system","accent":"peach","ui_font":"system","mono_font":"m",
         "font_size":13,"ui_text_scale":1.2,"glow_strength":0.65}
        """
        let config = try decode(json)
        #expect(config.uiTextScale == 1.2)
    }

    @Test("default value is 1.0")
    func defaultValueIsOne() {
        #expect(AppearanceConfig.defaultValue.uiTextScale == 1.0)
    }

    @Test("in-range scale passes validation")
    func inRangeValidates() throws {
        var config = AppearanceConfig.defaultValue
        config.uiTextScale = 1.3
        try config.validate()
    }

    @Test("out-of-range scale fails validation")
    func outOfRangeThrows() {
        var config = AppearanceConfig.defaultValue
        config.uiTextScale = 2.0
        #expect(throws: ConfigLoadError.self) {
            try config.validate()
        }
    }
}
