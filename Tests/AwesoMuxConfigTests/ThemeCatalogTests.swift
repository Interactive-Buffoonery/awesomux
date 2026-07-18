import Testing
@testable import AwesoMuxConfig

@Suite("Terminal theme catalog")
struct ThemeCatalogTests {
    @Test("Catppuccin provider exposes current Mocha and Latte terminal colors")
    func catppuccinProviderExposesCurrentTerminalColors() {
        let provider = CatppuccinThemeProvider()

        #expect(provider.background(for: .dark) == "#1e1e2e")
        #expect(provider.background(for: .light) == "#eff1f5")
        #expect(provider.foreground(for: .dark) == "#cdd6f4")
        #expect(provider.foreground(for: .light) == "#4c4f69")
        #expect(
            provider.ansi16(for: .dark) == [
                "#45475a",
                "#f38ba8",
                "#a6e3a1",
                "#f9e2af",
                "#89b4fa",
                "#f5c2e7",
                "#94e2d5",
                "#a6adc8",
                "#585b70",
                "#f37799",
                "#89d88b",
                "#ebd391",
                "#74a8fc",
                "#f2aede",
                "#6bd7ca",
                "#bac2de",
            ])
        #expect(
            provider.ansi16(for: .light) == [
                "#5c5f77",
                "#d20f39",
                "#40a02b",
                "#df8e1d",
                "#1e66f5",
                "#ea76cb",
                "#179299",
                "#acb0be",
                "#6c6f85",
                "#de293e",
                "#49af3d",
                "#eea02d",
                "#456eff",
                "#fe85d8",
                "#2d9fa8",
                "#bcc0cc",
            ])
    }

    @Test("catalog resolves nil and Catppuccin id to the built-in provider")
    func catalogResolvesNilAndCatppuccinID() {
        let catalog = TerminalThemeCatalog.builtIn

        #expect(catalog.provider(matching: TerminalThemeCatalog.catppuccinID) != nil)
        #expect(catalog.provider(matching: "solarized") == nil)
        #expect(catalog.provider(for: nil).background(for: .dark) == "#1e1e2e")
        #expect(catalog.provider(for: TerminalThemeCatalog.catppuccinID).foreground(for: .light) == "#4c4f69")
    }

    @Test("catalog can resolve a registered non-default provider")
    func catalogCanResolveRegisteredProvider() {
        let catalog = TerminalThemeCatalog(providers: [
            "test": TestTerminalThemeProvider()
        ])

        #expect(catalog.provider(matching: "test")?.background(for: .dark) == "#000000")
        #expect(catalog.provider(for: "test").foreground(for: .light) == "#eeeeee")
        #expect(catalog.provider(for: "missing").background(for: .dark) == "#1e1e2e")
    }

    @Test("Selenized provider exposes canonical White and Dark terminal colors")
    func selenizedProviderExposesCanonicalTerminalColors() {
        let provider = SelenizedThemeProvider()

        #expect(provider.background(for: .light) == "#ffffff")
        #expect(provider.foreground(for: .light) == "#474747")
        #expect(
            provider.ansi16(for: .light) == [
                "#ebebeb", "#d6000c", "#1d9700", "#c49700",
                "#0064e4", "#dd0f9d", "#00ad9c", "#878787",
                "#cdcdcd", "#bf0000", "#008400", "#af8500",
                "#0054cf", "#c7008b", "#009a8a", "#282828",
            ])
        #expect(provider.background(for: .dark) == "#103c48")
        #expect(provider.foreground(for: .dark) == "#adbcbc")
        #expect(
            provider.ansi16(for: .dark) == [
                "#184956", "#fa5750", "#75b938", "#dbb32d",
                "#4695f7", "#f275be", "#41c7b9", "#72898f",
                "#2d5b69", "#ff665c", "#84c747", "#ebc13d",
                "#58a3ff", "#ff84cd", "#53d6c7", "#cad8d9",
            ])
    }

    @Test("catalog resolves the built-in Selenized provider")
    func catalogResolvesBuiltInSelenizedProvider() {
        let catalog = TerminalThemeCatalog.builtIn
        let provider = catalog.provider(matching: TerminalThemeCatalog.selenizedID)
        let normalizedProvider = catalog.provider(matching: "  SELENIZED\n")

        #expect(provider != nil)
        #expect(normalizedProvider != nil)
        #expect(provider?.background(for: .light) == "#ffffff")
        #expect(provider?.background(for: .dark) == "#103c48")
    }

    @Test("Selenized uses the generic Ghostty color configuration fallback")
    func selenizedUsesGenericGhosttyColorConfigurationFallback() {
        let ansi16 = SelenizedThemeProvider().ansi16(for: .light)
        let lines = TerminalThemeCatalog.builtIn.ghosttyColorConfigLines(
            for: TerminalThemeCatalog.selenizedID,
            theme: .light
        )
        let expectedPaletteLines = ansi16.enumerated().map { index, hex in
            "palette = \(index)=\(hex)"
        }

        #expect(lines.filter { $0.hasPrefix("palette = ") } == expectedPaletteLines)
        #expect(lines.filter { $0 == "foreground = #474747" }.count == 1)
        #expect(lines.count == 17)
        #expect(!lines.contains { $0.hasPrefix("cursor-color") })
        #expect(!lines.contains { $0.hasPrefix("selection-background") })
        #expect(!lines.contains { $0.hasPrefix("selection-foreground") })
    }
}

private struct TestTerminalThemeProvider: TerminalThemeProvider {
    func background(for theme: TerminalAppearancePreferences.EffectiveTheme) -> String {
        switch theme {
        case .light: "#ffffff"
        case .dark: "#000000"
        }
    }

    func foreground(for theme: TerminalAppearancePreferences.EffectiveTheme) -> String {
        switch theme {
        case .light: "#eeeeee"
        case .dark: "#111111"
        }
    }

    func ansi16(for theme: TerminalAppearancePreferences.EffectiveTheme) -> [String] {
        Array(repeating: foreground(for: theme), count: 16)
    }
}
