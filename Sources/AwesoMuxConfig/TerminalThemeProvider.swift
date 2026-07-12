public protocol TerminalThemeProvider: Sendable {
    func background(for theme: TerminalAppearancePreferences.EffectiveTheme) -> String
    func foreground(for theme: TerminalAppearancePreferences.EffectiveTheme) -> String
    func ansi16(for theme: TerminalAppearancePreferences.EffectiveTheme) -> [String]
}
