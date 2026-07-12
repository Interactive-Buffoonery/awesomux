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
        #expect(provider.ansi16(for: .dark) == [
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
            "#bac2de"
        ])
        #expect(provider.ansi16(for: .light) == [
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
            "#bcc0cc"
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
