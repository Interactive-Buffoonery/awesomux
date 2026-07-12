import AwesoMuxConfig
import Testing
@testable import awesoMux

// `preferences(for:fallbackEffectiveTheme:)` is a lookup, not a self-memoizing
// cache: it never calls `update(_:)` itself. Only `update(_:)` writes
// `current`. These tests exercise the lookup's hit/miss comparison and its
// purity, not identity/reuse (a struct hit and a fresh construction are
// value-equal whenever every compared field matches, by design).
@MainActor
@Suite("TerminalAppearancePreferencesCache")
struct TerminalAppearancePreferencesCacheTests {
    @Test("cold start with no prior update returns a freshly constructed value")
    func coldStartReturnsFreshValue() {
        let cache = TerminalAppearancePreferencesCache()
        let appearance = AppearanceConfig.defaultValue

        let result = cache.preferences(for: appearance, fallbackEffectiveTheme: .dark)

        #expect(result == TerminalAppearancePreferences(appearance: appearance, effectiveTheme: .dark))
    }

    @Test("all compared fields match (incl. effectiveTheme): returned value equals current")
    func valueMatchesExpectedConstructionWhenFieldsAlign() {
        // NOTE: this does not prove the `if let current` hit-branch actually
        // executed — TerminalAppearancePreferences is a value type, and every
        // field the guard compares is also every field fresh construction
        // uses, so a hit and an equivalent fresh value are `==` either way.
        // The missOn* tests below are what actually pin the hit/miss branch.
        let cache = TerminalAppearancePreferencesCache()
        let appearance = AppearanceConfig.defaultValue
        cache.update(TerminalAppearancePreferences(appearance: appearance, effectiveTheme: .dark))

        let result = cache.preferences(for: appearance, fallbackEffectiveTheme: .dark)

        #expect(result == cache.current)
    }

    @Test("miss: effectiveTheme flip changes the derived catppuccin background, not just the field")
    func missOnEffectiveThemeFlipChangesBackground() {
        // The PR #111 regression: with Theme=System + catppuccin background,
        // a macOS Light/Dark flip must invalidate the cache or a
        // newly-spawned surface gets the wrong background color.
        var appearance = AppearanceConfig.defaultValue
        appearance.terminalBackgroundMode = .catppuccinTheme
        let cache = TerminalAppearancePreferencesCache()
        cache.update(TerminalAppearancePreferences(appearance: appearance, effectiveTheme: .dark))

        let result = cache.preferences(for: appearance, fallbackEffectiveTheme: .light)

        #expect(result.effectiveTheme == .light)
        #expect(result.ghosttyBackgroundColor != cache.current?.ghosttyBackgroundColor)
    }

    @Test("miss: monoFont change returns a fresh value")
    func missOnMonoFontChange() {
        let cache = TerminalAppearancePreferencesCache()
        var appearance = AppearanceConfig.defaultValue
        cache.update(TerminalAppearancePreferences(appearance: appearance, effectiveTheme: .dark))

        appearance.monoFont = "Menlo"
        let result = cache.preferences(for: appearance, fallbackEffectiveTheme: .dark)

        #expect(result.monoFont == "Menlo")
        #expect(result != cache.current)
    }

    @Test("miss: fontSize change returns a fresh value")
    func missOnFontSizeChange() {
        let cache = TerminalAppearancePreferencesCache()
        var appearance = AppearanceConfig.defaultValue
        cache.update(TerminalAppearancePreferences(appearance: appearance, effectiveTheme: .dark))

        appearance.fontSize = appearance.fontSize + 4
        let result = cache.preferences(for: appearance, fallbackEffectiveTheme: .dark)

        #expect(result.fontSize == appearance.fontSize)
        #expect(result != cache.current)
    }

    @Test("miss: terminalBackgroundMode change returns a fresh value")
    func missOnTerminalBackgroundModeChange() {
        let cache = TerminalAppearancePreferencesCache()
        var appearance = AppearanceConfig.defaultValue
        appearance.terminalBackgroundMode = .ghostty
        cache.update(TerminalAppearancePreferences(appearance: appearance, effectiveTheme: .dark))

        appearance.terminalBackgroundMode = .catppuccinTheme
        let result = cache.preferences(for: appearance, fallbackEffectiveTheme: .dark)

        #expect(result.terminalBackgroundMode == .catppuccinTheme)
        #expect(result != cache.current)
    }

    @Test("miss: terminalBackgroundColor change returns a fresh value")
    func missOnTerminalBackgroundColorChange() {
        let cache = TerminalAppearancePreferencesCache()
        var appearance = AppearanceConfig.defaultValue
        appearance.terminalBackgroundColor = "#111111"
        cache.update(TerminalAppearancePreferences(appearance: appearance, effectiveTheme: .dark))

        appearance.terminalBackgroundColor = "#222222"
        let result = cache.preferences(for: appearance, fallbackEffectiveTheme: .dark)

        #expect(result.terminalBackgroundColor == "#222222")
        #expect(result != cache.current)
    }

    @Test("miss: terminalThemeID change returns a fresh value")
    func missOnTerminalThemeIDChange() {
        let cache = TerminalAppearancePreferencesCache()
        var appearance = AppearanceConfig.defaultValue
        cache.update(TerminalAppearancePreferences(appearance: appearance, effectiveTheme: .dark))

        appearance.terminalThemeID = TerminalThemeCatalog.catppuccinID
        let result = cache.preferences(for: appearance, fallbackEffectiveTheme: .dark)

        #expect(result.terminalThemeID == TerminalThemeCatalog.catppuccinID)
        #expect(result != cache.current)
    }

    @Test("update(_:) swaps the stored value")
    func updateSwapsStoredValue() {
        let cache = TerminalAppearancePreferencesCache()
        let first = TerminalAppearancePreferences(monoFont: "Menlo")
        let second = TerminalAppearancePreferences(monoFont: "Hack Nerd Font Mono")

        cache.update(first)
        #expect(cache.current == first)

        cache.update(second)
        #expect(cache.current == second)
    }

    @Test("lookups are pure: a miss never writes current, only update(_:) does")
    func lookupsDoNotMutateCurrent() {
        let cache = TerminalAppearancePreferencesCache()
        var appearance = AppearanceConfig.defaultValue
        cache.update(TerminalAppearancePreferences(appearance: appearance, effectiveTheme: .dark))
        let before = cache.current

        appearance.monoFont = "Menlo"
        let result = cache.preferences(for: appearance, fallbackEffectiveTheme: .dark)

        #expect(result != before)
        #expect(cache.current == before)
    }

    @Test("hex casing tolerance: differently-cased hex produces an equal value, not a spurious miss")
    func hexCasingToleranceProducesEqualValue() {
        // Normalization happens both at TerminalAppearancePreferences.init
        // (so `current` is always stored lowercased) and again at
        // comparison time in preferences(for:) — both sides of the
        // comparison go through the same normalizer, so casing alone
        // cannot cause a spurious miss. (Same caveat as the hit test above:
        // this proves value correctness, not that the hit branch fired.)
        var appearance = AppearanceConfig.defaultValue
        appearance.terminalBackgroundColor = "#ABCDEF"
        let cache = TerminalAppearancePreferencesCache()
        cache.update(TerminalAppearancePreferences(appearance: appearance, effectiveTheme: .dark))

        appearance.terminalBackgroundColor = "#abcdef"
        let result = cache.preferences(for: appearance, fallbackEffectiveTheme: .dark)

        #expect(result == cache.current)
    }
}
