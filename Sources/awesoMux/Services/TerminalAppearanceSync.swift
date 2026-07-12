import AppKit
import AwesoMuxConfig
import SwiftUI

struct TerminalAppearanceSync: ViewModifier {
    // 75ms is short enough to feel instant on a click/preset-tap but long
    // enough to coalesce a SwiftUI `ColorPicker` drag (30–60Hz value
    // updates) into a single apply. Without this, every drag tick
    // triggers a full libghostty config rebuild — including disk reads of
    // the user's `~/.config/ghostty/config` and recursive imports — and
    // a VoiceOver "Terminal appearance updated" announcement.
    private static let applyDebounceMilliseconds: UInt64 = 75

    let appSettingsStore: AppSettingsStore
    let ghosttyRuntime: GhosttyRuntime
    let preferencesCache: TerminalAppearancePreferencesCache

    @Environment(\.colorScheme) private var colorScheme
    @State private var lastAppliedPreferences: TerminalAppearancePreferences?
    @State private var pendingApply: Task<Void, Never>?

    func body(content: Content) -> some View {
        let appearance = appSettingsStore.appearance.value
        let preferences = TerminalAppearancePreferences(
            appearance: appearance,
            effectiveTheme: effectiveTheme(for: appearance)
        )

        content
            .onChange(of: preferences) { oldPreferences, preferences in
                if lastAppliedPreferences == nil {
                    lastAppliedPreferences = oldPreferences
                }
                schedule(preferences)
            }
    }

    private func schedule(_ preferences: TerminalAppearancePreferences) {
        pendingApply?.cancel()
        pendingApply = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.applyDebounceMilliseconds * 1_000_000)
            if Task.isCancelled { return }
            apply(preferences, announce: true)
        }
    }

    private func apply(_ preferences: TerminalAppearancePreferences, announce: Bool) {
        ghosttyRuntime.applyTerminalAppearance(preferences)
        preferencesCache.update(preferences)

        if announce, let message = Self.announcementMessage(from: lastAppliedPreferences, to: preferences) {
            // Route through the shared helper (not a raw `NSAccessibility.post`)
            // so the commit-time announcement gets its async next-runloop-tick
            // hop — load-bearing here because the font-size slider's commit
            // gesture IS a drag teardown, exactly the case
            // `TerminalAccessibilityAnnouncer.announce`'s doc warns can swallow
            // a synchronous post.
            //
            // `.medium`, not the `.low` this message historically used:
            // VoiceOver drops `.low` announcements while mid-utterance, and
            // on a slider release it's likely still speaking the slider's own
            // value readback — dropping the cross-pane status message is the
            // exact WCAG 4.1.3 failure this announcement exists to prevent
            // (flagged independently by both review passes).
            TerminalAccessibilityAnnouncer.announce(message, priority: .medium)
        }
        lastAppliedPreferences = preferences
    }

    /// `nil` means no announcement (change wasn't user-meaningful).
    ///
    /// Only announce on user-meaningful changes. A macOS Light/Dark flip
    /// while Theme=System changes `effectiveTheme` without the user
    /// touching awesoMux settings — announcing that would spam VoiceOver
    /// on every OS appearance toggle.
    ///
    /// Internal (not `private`) so `TerminalAppearanceSyncTests` can drive
    /// this branch logic directly instead of round-tripping the whole
    /// `ViewModifier` + `AppSettingsStore` + `GhosttyRuntime` stack.
    static func announcementMessage(
        from old: TerminalAppearancePreferences?,
        to new: TerminalAppearancePreferences
    ) -> String? {
        guard isUserMeaningfulChange(from: old, to: new) else { return nil }
        guard let old else {
            // Unreachable in the live modifier because `.onChange` seeds
            // `lastAppliedPreferences` from SwiftUI's old value before
            // scheduling the first announced apply; kept total for the pure
            // function.
            return String(
                localized: "Terminal appearance updated",
                comment: "VoiceOver announcement after a user-driven terminal appearance change."
            )
        }

        // Font changes get copy naming the value that just took effect on
        // already-open panes (WCAG 4.1.3, INT-388) — the generic
        // "Terminal appearance updated" fallback below doesn't tell
        // VoiceOver users *what* changed. Checked ahead of the fallback so
        // a font commit never reads as a bare theme/background update.
        // If both a font-size drag-release and a font-family pick land in
        // the same 75ms debounce window, font size wins — narrower/rarer
        // than worth a combined-message branch.
        if old.ghosttyFontSize != new.ghosttyFontSize {
            // Speak the value libghostty applied (`ghosttyFontSize` clamps
            // and NaN-guards; the same accessor feeds the actual config),
            // never a rounding of it — a hand-edited `font-size = 13.5`
            // must not be announced as "14 points". WCAG status messages
            // report actual state.
            let applied = Double(new.ghosttyFontSize)
            if applied.rounded() == applied {
                return LocalizedPluralStrings.fontSizeApplied(points: Int(applied))
            }
            // Fractional sizes only arrive via a hand-edited config file —
            // the slider commits whole points. The sentence is translated
            // whole, so translators own the unit grammar; the stringsdict
            // plural machinery can't take a fractional argument anyway.
            // Spoken precision capped at 2 fraction digits because the
            // ghostty config writer emits %.2f — a hand-edited 13.333
            // applies as 13.33, and the announcement must match.
            return String(
                localized: "Font size updated to \(applied.formatted(.number.precision(.fractionLength(0...2)))) points. Open terminal panes refreshed.",
                comment: "VoiceOver announcement after a fractional terminal font size change from a hand-edited config. Argument is the applied point size, e.g. 13.5."
            )
        }
        if old.ghosttyFontFamily != new.ghosttyFontFamily {
            return String(
                localized: "Font updated to \(fontDisplayName(new)). Open terminal panes refreshed.",
                comment: "VoiceOver announcement after committing a terminal font family change."
            )
        }
        return String(
            localized: "Terminal appearance updated",
            comment: "VoiceOver announcement after a user-driven terminal appearance change."
        )
    }

    /// Speaks the family libghostty actually applied; `nil` (no override —
    /// sentinel, empty, or rejected value) reads as the default. A short
    /// spoken name, not the full picker-menu label (no "(Bundled)"/
    /// "(missing)" suffixes) — good enough for a transient commit
    /// confirmation.
    /// ponytail: revisit with the picker's full display-name resolution
    /// (`SettingsFontPickerMenu.currentLabel`) if VoiceOver users report
    /// the bare family name as ambiguous.
    private static func fontDisplayName(_ preferences: TerminalAppearancePreferences) -> String {
        preferences.ghosttyFontFamily
            ?? String(
                localized: "System default",
                comment: "Spoken name for the terminal's default monospace font when no override is set."
            )
    }

    private static func isUserMeaningfulChange(
        from old: TerminalAppearancePreferences?,
        to new: TerminalAppearancePreferences
    ) -> Bool {
        guard let old else { return true }
        // Compare `ghosttyBackgroundColor` (the rendered end state) rather
        // than raw `effectiveTheme` so a macOS Light/Dark flip in
        // `.catppuccinTheme` mode — which actually changes the visible bg
        // from Mocha to Latte — still announces, while OS flips in
        // `.ghostty` or `.custom` mode (which don't change the visible
        // bg) stay silent. Without this, Codex flagged that VoiceOver
        // users miss real appearance changes in Catppuccin mode.
        //
        // Fonts compare *applied* state (`ghosttyFontFamily` /
        // `ghosttyFontSize`) for the same reason: a hand-edit the config
        // boundary normalizes away (" Menlo " -> "Menlo", 100 -> clamp 72)
        // changes nothing on screen, so announcing it would report a state
        // change that didn't happen.
        return old.ghosttyFontFamily != new.ghosttyFontFamily
            || old.ghosttyFontSize != new.ghosttyFontSize
            || old.terminalBackgroundMode != new.terminalBackgroundMode
            || old.terminalBackgroundColor != new.terminalBackgroundColor
            || old.ghosttyBackgroundColor != new.ghosttyBackgroundColor
    }

    private func effectiveTheme(for appearance: AppearanceConfig) -> TerminalAppearancePreferences.EffectiveTheme {
        switch appearance.theme {
        case .light:
            .light
        case .dark:
            .dark
        case .system:
            colorScheme == .light ? .light : .dark
        }
    }
}

extension View {
    func terminalAppearanceSync(
        appSettingsStore: AppSettingsStore,
        ghosttyRuntime: GhosttyRuntime,
        preferencesCache: TerminalAppearancePreferencesCache
    ) -> some View {
        modifier(TerminalAppearanceSync(
            appSettingsStore: appSettingsStore,
            ghosttyRuntime: ghosttyRuntime,
            preferencesCache: preferencesCache
        ))
    }
}
