public struct CatppuccinThemeProvider: TerminalThemeProvider {
    public init() {}

    public func background(for theme: TerminalAppearancePreferences.EffectiveTheme) -> String {
        variant(for: theme).background
    }

    public func foreground(for theme: TerminalAppearancePreferences.EffectiveTheme) -> String {
        variant(for: theme).foreground
    }

    public func ansi16(for theme: TerminalAppearancePreferences.EffectiveTheme) -> [String] {
        variant(for: theme).ansi16
    }

    public static var backgroundPresets: [(name: String, hex: String)] {
        [
            ("Base", mocha.background),
            ("Mantle", "#181825"),
            ("Crust", "#11111b"),
            ("Surface 0", "#313244"),
            ("Latte Base", latte.background),
            ("Latte Mantle", "#e6e9ef"),
            ("Latte Crust", "#dce0e8"),
            ("Latte Surface 0", "#ccd0da")
        ]
    }

    func ghosttyColorConfigLines(for theme: TerminalAppearancePreferences.EffectiveTheme) -> [String] {
        let variant = variant(for: theme)
        var lines = variant.ansi16.enumerated().map { index, hex in
            "palette = \(index)=\(hex)"
        }
        lines.append("foreground = \(variant.foreground)")
        lines.append("cursor-color = \(variant.cursorColor)")
        lines.append("cursor-text = \(variant.cursorText)")
        lines.append("selection-background = \(variant.selectionBackground)")
        lines.append("selection-foreground = \(variant.selectionForeground)")
        return lines
    }

    private func variant(for theme: TerminalAppearancePreferences.EffectiveTheme) -> Variant {
        switch theme {
        case .light: Self.latte
        case .dark: Self.mocha
        }
    }

    private static let latte = Variant(
        background: "#eff1f5",
        foreground: "#4c4f69",
        ansi16: [
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
        ],
        cursorColor: "#dc8a78",
        cursorText: "#eff1f5",
        selectionBackground: "#acb0be",
        selectionForeground: "#4c4f69"
    )

    private static let mocha = Variant(
        background: "#1e1e2e",
        foreground: "#cdd6f4",
        ansi16: [
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
        ],
        cursorColor: "#f5e0dc",
        cursorText: "#1e1e2e",
        selectionBackground: "#585b70",
        selectionForeground: "#cdd6f4"
    )
}

private struct Variant: Sendable {
    var background: String
    var foreground: String
    var ansi16: [String]
    var cursorColor: String
    var cursorText: String
    var selectionBackground: String
    var selectionForeground: String
}
