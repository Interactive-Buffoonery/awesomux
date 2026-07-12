import AppKit
import Testing
@testable import DesignSystem

@Suite("Bundled font registration")
struct FontRegistrationTests {
    @Test("Geist resources register every supported UI weight")
    func registersGeistWeights() throws {
        let result = DesignSystemFonts.registerBundledFonts()

        #expect(result.failures.isEmpty)
        #expect(result.registeredPostScriptNames == [
            "Geist-Regular",
            "Geist-Medium",
            "Geist-SemiBold",
            "Geist-Bold"
        ])

        let manager = NSFontManager.shared
        let expectedFaces: [(weight: Int, postScriptName: String)] = [
            (5, "Geist-Regular"),
            (6, "Geist-Medium"),
            (8, "Geist-SemiBold"),
            (9, "Geist-Bold")
        ]
        for expected in expectedFaces {
            let font = try #require(manager.font(
                withFamily: DesignSystemFonts.geistFamilyName,
                traits: [],
                weight: expected.weight,
                size: 13
            ))
            #expect(font.fontName == expected.postScriptName)
        }
    }

    @Test("registration is idempotent")
    func registrationIsIdempotent() {
        let first = DesignSystemFonts.registerBundledFonts()
        let second = DesignSystemFonts.registerBundledFonts()

        #expect(second == first)
    }
}
