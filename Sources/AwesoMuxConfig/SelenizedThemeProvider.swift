public struct SelenizedThemeProvider: TerminalThemeProvider {
    public init() {}

    public func background(
        for theme: TerminalAppearancePreferences.EffectiveTheme
    ) -> String {
        variant(for: theme).background
    }

    public func foreground(
        for theme: TerminalAppearancePreferences.EffectiveTheme
    ) -> String {
        variant(for: theme).foreground
    }

    public func ansi16(
        for theme: TerminalAppearancePreferences.EffectiveTheme
    ) -> [String] {
        variant(for: theme).ansi16
    }

    private func variant(
        for theme: TerminalAppearancePreferences.EffectiveTheme
    ) -> Variant {
        switch theme {
        case .light: Self.white
        case .dark: Self.dark
        }
    }

    // Selenized (github.com/jan-warchol/selenized, MIT, pinned tag v1.0).
    // Hex values copied verbatim from the upstream xterm color definitions
    // (terminals/xterm/selenized-white.xdefaults and
    // terminals/xterm/selenized-dark.xdefaults) — not re-tuned. The "white"
    // background variant is used for .light (Selenized's own highest-contrast
    // light variant, chosen over the cream "light" variant because it clears
    // more ANSI slots at 4.5:1); "dark" pairs it for .dark so both
    // EffectiveTheme cases resolve to a real Selenized palette rather than
    // leaving dark undefined.
    private static let white = Variant(
        background: "#ffffff",
        foreground: "#474747",
        ansi16: [
            "#ebebeb", "#d6000c", "#1d9700", "#c49700",
            "#0064e4", "#dd0f9d", "#00ad9c", "#878787",
            "#cdcdcd", "#bf0000", "#008400", "#af8500",
            "#0054cf", "#c7008b", "#009a8a", "#282828",
        ]
    )

    private static let dark = Variant(
        background: "#103c48",
        foreground: "#adbcbc",
        ansi16: [
            "#184956", "#fa5750", "#75b938", "#dbb32d",
            "#4695f7", "#f275be", "#41c7b9", "#72898f",
            "#2d5b69", "#ff665c", "#84c747", "#ebc13d",
            "#58a3ff", "#ff84cd", "#53d6c7", "#cad8d9",
        ]
    )
}

private struct Variant: Sendable {
    let background: String
    let foreground: String
    let ansi16: [String]
}
