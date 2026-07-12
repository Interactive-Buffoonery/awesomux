import AwesoMuxConfig

@MainActor
final class TerminalAppearancePreferencesCache {
    private(set) var current: TerminalAppearancePreferences?

    func update(_ preferences: TerminalAppearancePreferences) {
        current = preferences
    }

    func preferences(
        for appearance: AppearanceConfig,
        fallbackEffectiveTheme: TerminalAppearancePreferences.EffectiveTheme
    ) -> TerminalAppearancePreferences {
        // `effectiveTheme` MUST be part of the cache-hit comparison: the
        // Catppuccin background mode resolves to a different hex per theme,
        // so a macOS Light/Dark flip while `Theme=System` must invalidate
        // the cache or new-spawned surfaces get a stale background.
        if let current,
           current.effectiveTheme == fallbackEffectiveTheme,
           current.monoFont == appearance.monoFont,
           current.fontSize == appearance.fontSize,
           current.terminalBackgroundMode == appearance.terminalBackgroundMode,
           current.terminalBackgroundColor == AppearanceConfig.normalizedTerminalBackgroundColor(appearance.terminalBackgroundColor),
           current.terminalThemeID == appearance.terminalThemeID {
            return current
        }

        return TerminalAppearancePreferences(
            appearance: appearance,
            effectiveTheme: fallbackEffectiveTheme
        )
    }
}
