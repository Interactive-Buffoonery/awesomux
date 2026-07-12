import AppKit
import AwesoMuxConfig
import Testing
@testable import awesoMux

@Suite("Terminal effective theme")
struct TerminalEffectiveThemeTests {
    @Test("explicit app themes ignore AppKit appearance")
    @MainActor
    func explicitAppThemesIgnoreAppKitAppearance() throws {
        let lightAppearance = try #require(NSAppearance(named: .aqua))
        let darkAppearance = try #require(NSAppearance(named: .darkAqua))

        #expect(terminalEffectiveTheme(
            for: AppearanceConfig(theme: .light),
            effectiveAppearance: darkAppearance
        ) == .light)
        #expect(terminalEffectiveTheme(
            for: AppearanceConfig(theme: .dark),
            effectiveAppearance: lightAppearance
        ) == .dark)
    }

    @Test("system app theme follows AppKit appearance when available")
    @MainActor
    func systemAppThemeFollowsAppKitAppearanceWhenAvailable() throws {
        let lightAppearance = try #require(NSAppearance(named: .aqua))
        let darkAppearance = try #require(NSAppearance(named: .darkAqua))
        let systemAppearance = AppearanceConfig(theme: .system)

        #expect(terminalEffectiveTheme(
            for: systemAppearance,
            effectiveAppearance: lightAppearance
        ) == .light)
        #expect(terminalEffectiveTheme(
            for: systemAppearance,
            effectiveAppearance: darkAppearance
        ) == .dark)
    }

    @Test("system app theme falls back before NSApp exists")
    @MainActor
    func systemAppThemeFallsBackBeforeNSAppExists() {
        let systemAppearance = AppearanceConfig(theme: .system)

        #expect(terminalEffectiveTheme(
            for: systemAppearance,
            effectiveAppearance: nil,
            interfaceStyle: "Dark"
        ) == .dark)
        #expect(terminalEffectiveTheme(
            for: systemAppearance,
            effectiveAppearance: nil,
            interfaceStyle: nil
        ) == .light)
    }
}
