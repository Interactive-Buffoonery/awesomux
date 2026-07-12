import Testing
@testable import awesoMux
import DesignSystem

/// Exercises the LIVE `appearance.ui_font` probe (`resolvedForSystem`) against
/// the real installed font catalog, using families that ship with every macOS:
/// Helvetica (proportional) and Menlo (monospaced).
@Suite("Appearance UI font resolution")
@MainActor
struct AppearanceUIFontResolutionTests {
    @Test("bundled Geist resolves to the registered family")
    func bundledGeistResolves() {
        _ = DesignSystemFonts.registerBundledFonts()

        let resolver = AwUIFontResolver.resolvedForSystem(rawFamily: "geist")
        #expect(resolver.family == DesignSystemFonts.geistFamilyName)
    }

    @Test("bundled Geist is the first proportional picker family")
    func bundledGeistIsFirstPickerFamily() throws {
        _ = DesignSystemFonts.registerBundledFonts()
        SettingsFontCatalog.cachedProportional = nil
        SettingsFontCatalog.cachedProportionalIndex = nil

        let first = try #require(SettingsFontFamily.installed(monospaced: false).first)
        #expect(first.name == DesignSystemFonts.geistFamilyName)
        #expect(first.displayName == "Geist")
    }

    @Test("a differently-cased installed proportional family canonicalizes to the catalog spelling")
    func caseInsensitiveMatchCanonicalizes() {
        let resolver = AwUIFontResolver.resolvedForSystem(rawFamily: "hELVETICA")
        #expect(resolver.family == "Helvetica")
    }

    @Test("a monospaced family falls back to system, same as uninstalled")
    func monospaceFamilyFallsBack() {
        // The Interface font picker only offers proportional families; a
        // hand-edited monospace ui_font must not sneak past the probe.
        let resolver = AwUIFontResolver.resolvedForSystem(rawFamily: "Menlo")
        #expect(resolver.family == nil)
    }

    @Test("an uninstalled family falls back to system")
    func uninstalledFamilyFallsBack() {
        let resolver = AwUIFontResolver.resolvedForSystem(rawFamily: "Definitely Not A Font 42")
        #expect(resolver.family == nil)
    }

    @Test("the stored \"system\" sentinel resolves to the system font")
    func systemSentinelFallsBack() {
        #expect(AwUIFontResolver.resolvedForSystem(rawFamily: "system").family == nil)
    }
}
