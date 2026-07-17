import AppKit
import AwesoMuxConfig
import DesignSystem
import SwiftUI

struct AppearanceSettingsPane: View {
    private static let glowStrengthSyncEpsilon = 0.001
    private static let fontSizeSyncEpsilon = 0.5
    private static let textScaleSyncEpsilon = 0.001

    @Environment(AppSettingsStore.self) private var appSettingsStore
    @State private var draftGlowStrength: Double = 0.65
    @State private var draftFontSize: Double = 13
    @State private var draftTextScale: Double = AwTextScale.defaultValue
    @State private var monoFonts: [SettingsFontFamily] = []
    @State private var uiFonts: [SettingsFontFamily] = []
    // Owned here (not inside TerminalBackgroundSettings) so resetToDefaults() can
    // cancel the debounce and resync the draft synchronously in the same call,
    // rather than signaling the child and waiting for a SwiftUI onChange pass to
    // catch up — a reactive signal isn't guaranteed to win a race against an
    // already-scheduled Task resumption (see resetToDefaults() below).
    @State private var draftColorHex: String = ""
    @State private var pendingColorCommit: Task<Void, Never>?

    private var appearance: AppearanceConfig {
        appSettingsStore.appearance.value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(
                index: 1,
                title: String(localized: "Theme", comment: "Appearance settings section title"),
                subtitle: String(localized: "Mocha, Latte, or follow the system appearance.", comment: "Theme section subtitle")
            ) {
                SettingsField(label: String(localized: "Theme", comment: "Settings field label for the theme picker"), isFirst: true) {
                    SettingsThemePreview(
                        selection: appSettingsStore.binding(\.appearance.theme),
                        variant: .grid
                    )
                }

                SettingsField(
                    label: String(
                        localized: "Terminal background", comment: "Settings field label for the terminal background source picker"),
                    hint: String(
                        localized:
                            "Use Ghostty config to keep imported/user terminal themes, or choose an awesoMux color from Catppuccin presets and adjust it if needed.",
                        comment: "Settings field hint for the terminal background source picker")
                ) {
                    TerminalBackgroundSettings(
                        theme: appearance.theme,
                        terminalThemeID: appearance.terminalThemeID,
                        mode: appSettingsStore.binding(\.appearance.terminalBackgroundMode),
                        colorHex: appSettingsStore.binding(\.appearance.terminalBackgroundColor),
                        draftColorHex: $draftColorHex,
                        pendingCommit: $pendingColorCommit
                    )
                }
            }

            SettingsSection(index: 2, title: String(localized: "Accent", comment: "Appearance settings section title")) {
                SettingsField(
                    label: String(localized: "Accent color", comment: "Settings field label for the accent color swatches"),
                    hint: String(
                        localized: "Tints active sidebar rows, focus outlines, and progress affordances.",
                        comment: "Settings field hint for the accent color swatches"),
                    isFirst: true
                ) {
                    SettingsSwatchGrid(selection: accentBinding)
                }
            }

            SettingsSection(
                index: 3,
                title: String(localized: "Fonts", comment: "Appearance settings section title"),
                subtitle: String(
                    localized: "Interface font applies to app chrome; terminal typography applies to existing and new panes.",
                    comment: "Fonts section subtitle")
            ) {
                SettingsField(
                    label: String(localized: "Interface font", comment: "Settings field label for the app UI font picker"),
                    hint: String(
                        localized:
                            "Used across the sidebar, panels, and settings. Unavailable fonts fall back to the system font. Choose System (SF Pro) to restore the standard font.",
                        comment: "Settings field hint for the app UI font picker, including how to recover from a missing font"),
                    isFirst: true
                ) {
                    SettingsFontPickerMenu(
                        selection: appSettingsStore.binding(\.appearance.uiFont),
                        fieldLabel: String(localized: "Interface font", comment: "Accessibility label for the app UI font picker"),
                        systemValue: "system",
                        systemLabel: String(
                            localized: "System (SF Pro)", comment: "Font picker entry for the built-in macOS interface font"),
                        fonts: uiFonts
                    )
                }

                SettingsField(
                    label: String(localized: "Mono font", comment: "Settings field label for the terminal font picker"),
                    hint: String(
                        localized: "Used by the libghostty terminal surface.", comment: "Settings field hint for the terminal font picker")
                ) {
                    SettingsFontPickerMenu(
                        selection: appSettingsStore.binding(\.appearance.monoFont),
                        fieldLabel: String(localized: "Mono font", comment: "Accessibility label for the terminal font picker"),
                        systemValue: "system-monospace",
                        systemLabel: String(localized: "System default", comment: "Font picker entry for the built-in system font"),
                        fonts: monoFonts
                    )
                }

                SettingsField(
                    label: String(localized: "Font size", comment: "Settings field label for the terminal font size slider"),
                    hint: String(
                        localized: "Updates open terminal panes without restarting their shell.",
                        comment: "Settings field hint for the terminal font size slider")
                ) {
                    TerminalFontSizeSlider(
                        draftValue: $draftFontSize,
                        commit: commitFontSize
                    )
                }

                SettingsField(
                    label: String(localized: "Interface text size", comment: "Settings field label for the app UI text-size slider"),
                    hint: String(
                        localized:
                            "Scales sidebar, panel, and settings text. macOS has no system control for app text size, so this is awesoMux's. Doesn't affect the terminal grid.",
                        comment: "Settings field hint for the app UI text-size slider")
                ) {
                    InterfaceTextSizeSlider(
                        draftValue: $draftTextScale,
                        commit: commitTextScale
                    )
                }
            }

            SettingsSection(index: 4, title: String(localized: "Glow", comment: "Appearance settings section title")) {
                SettingsField(
                    label: String(localized: "Glow strength", comment: "Settings field label for the glow strength slider"),
                    hint: String(
                        localized: "Scales accent halos on the active sidebar rail and focus rings.",
                        comment: "Settings field hint for the glow strength slider"),
                    isFirst: true
                ) {
                    GlowSlider(
                        draftValue: $draftGlowStrength,
                        commit: commitGlowStrength
                    )
                }
            }

            SettingsSection(
                index: 5,
                title: String(localized: "CRT effect", comment: "Appearance settings section title"),
                subtitle: String(
                    localized: "Optional retro overlay on the terminal pane.",
                    comment: "CRT effect section subtitle")
            ) {
                SettingsField(
                    label: String(localized: "CRT scanlines", comment: "Settings field label for the CRT scanlines toggle"),
                    hint: String(
                        localized: "Visual-only overlay. Off by default.", comment: "Settings field hint for the CRT scanlines toggle"),
                    isFirst: true,
                    // Bare .labelsHidden() Toggle — let the field supply its name.
                    forwardsAccessibilityToControl: true
                ) {
                    Toggle("CRT scanlines", isOn: appSettingsStore.appearance.binding(\.crtScanlines))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            SettingsSection(
                index: 6,
                title: String(localized: "Sidebar", comment: "Appearance settings section title"),
                subtitle: String(
                    localized: "Position, row density, and collapsed-rail behavior.",
                    comment: "Sidebar section subtitle")
            ) {
                SettingsField(
                    label: String(localized: "Position", comment: "Settings field label for the sidebar position picker"),
                    isFirst: true
                ) {
                    Picker("Sidebar position", selection: appSettingsStore.appearance.binding(\.sidebarPosition)) {
                        Text("Left").tag(AppearanceConfig.SidebarPosition.left)
                        Text("Right").tag(AppearanceConfig.SidebarPosition.right)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Sidebar position")
                }

                SettingsField(
                    label: String(localized: "Compact mode", comment: "Settings field label for the sidebar compact mode toggle"),
                    hint: String(
                        localized: "Tighter row spacing for users with many sessions in a single workspace.",
                        comment: "Settings field hint for the sidebar compact mode toggle"),
                    // Bare .labelsHidden() Toggle — let the field supply its name.
                    forwardsAccessibilityToControl: true
                ) {
                    // Still GeneralConfig / `general.sidebar_compact_mode` on disk:
                    // moving the control here is a UI regrouping, not a config-key
                    // migration.
                    Toggle("Sidebar compact mode", isOn: appSettingsStore.general.binding(\.sidebarCompactMode))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsField(
                    label: String(
                        localized: "Always show jump numbers", comment: "Settings field label for the sidebar jump numbers toggle"),
                    hint: String(
                        localized:
                            "When the sidebar is collapsed, show the ⌘1–9 jump number under each workspace. Off by default — the numbers appear while you hold ⌘.",
                        comment: "Settings field hint for the sidebar jump numbers toggle"),
                    // Bare .labelsHidden() Toggle — let the field supply its name.
                    forwardsAccessibilityToControl: true
                ) {
                    Toggle("Always show jump numbers", isOn: appSettingsStore.appearance.binding(\.alwaysShowJumpNumbers))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            SettingsSection(index: 7, title: String(localized: "Reset", comment: "Appearance settings section title")) {
                SettingsField(
                    label: String(localized: "Reset to Defaults", comment: "Settings field label for the reset-to-defaults button"),
                    hint: String(
                        localized:
                            "Resets theme, accent, fonts, text size, glow, CRT scanlines, terminal background, sidebar position, and jump numbers to their shipped defaults. Doesn't touch sidebar compact mode or settings on other panes.",
                        comment: "Settings field hint for the reset-to-defaults button"),
                    isFirst: true
                ) {
                    Button("Reset to Defaults") { resetToDefaults() }
                        .accessibilityHint(
                            "Immediately resets all appearance settings on this page to their shipped defaults. This cannot be undone.")
                }
            }
        }
        .onAppear {
            draftGlowStrength = appearance.glowStrength
            draftFontSize = appearance.fontSize
            draftTextScale = appearance.uiTextScale
            draftColorHex = appearance.terminalBackgroundColor
            monoFonts = SettingsFontFamily.installed(monospaced: true)
            uiFonts = SettingsFontFamily.installed(monospaced: false)
        }
        .onChange(of: appearance.glowStrength) { _, newValue in
            if abs(newValue - draftGlowStrength) > Self.glowStrengthSyncEpsilon {
                draftGlowStrength = newValue
            }
        }
        .onChange(of: appearance.fontSize) { _, newValue in
            if abs(newValue - draftFontSize) > Self.fontSizeSyncEpsilon {
                draftFontSize = newValue
            }
        }
        .onChange(of: appearance.uiTextScale) { _, newValue in
            if abs(newValue - draftTextScale) > Self.textScaleSyncEpsilon {
                draftTextScale = newValue
            }
        }
        .onChange(of: appearance.terminalBackgroundColor) { _, newValue in
            // External writes (file watcher, settings reload, mode-flip side effect)
            // supersede any in-flight draft. Cancel the pending debounce so the next
            // gesture starts from the canonical store value.
            if newValue != draftColorHex {
                pendingColorCommit?.cancel()
                draftColorHex = newValue
            }
        }
    }

    private var accentBinding: Binding<AwAccent> {
        Binding(
            get: { AwAccent(configAccent: appearance.accent) },
            set: { newValue in
                appSettingsStore.appearance.update { appearance in
                    appearance.accent = newValue.configAccent
                }
            }
        )
    }

    private func commitFontSize(_ value: Double) {
        let safe = value.isFinite ? value : AppearanceConfig.defaultValue.fontSize
        let clamped = min(max(safe, 6), 72).rounded()
        appSettingsStore.appearance.update { appearance in
            appearance.fontSize = clamped
        }
    }

    private func commitTextScale(_ value: Double) {
        let clamped = AwTextScale.clamp(value)
        appSettingsStore.appearance.update { appearance in
            appearance.uiTextScale = clamped
        }
    }

    private func commitGlowStrength(_ value: Double) {
        appSettingsStore.appearance.update { appearance in
            appearance.glowStrength = value
        }
    }

    private func resetToDefaults() {
        let defaults = AppearanceConfig.defaultValue
        appSettingsStore.appearance.update { appearance in
            // Field-by-field, not a whole-struct replace: `cursorGlow` is a real
            // AppearanceConfig field but its control lives on
            // TerminalSettingsPane, not here. A user clicking "Reset to
            // Defaults" on the Appearance pane shouldn't see settings silently
            // change on a pane they're not looking at. (Sidebar compact mode has
            // its control here but persists via GeneralConfig, so it's also
            // outside this appearance-store reset — the hint copy says so.)
            appearance.theme = defaults.theme
            appearance.accent = defaults.accent
            appearance.uiFont = defaults.uiFont
            appearance.monoFont = defaults.monoFont
            appearance.fontSize = defaults.fontSize
            appearance.uiTextScale = defaults.uiTextScale
            appearance.glowStrength = defaults.glowStrength
            appearance.terminalThemeID = defaults.terminalThemeID
            appearance.terminalBackgroundMode = defaults.terminalBackgroundMode
            appearance.terminalBackgroundColor = defaults.terminalBackgroundColor
            appearance.alwaysShowJumpNumbers = defaults.alwaysShowJumpNumbers
            appearance.sidebarPosition = defaults.sidebarPosition
            appearance.crtScanlines = defaults.crtScanlines
        }
        // Read back from the store rather than the `defaults` constant above:
        // `AppearanceStore.update` only commits when the disk write succeeds
        // (SectionStores.swift `attemptPersist`) — on a save failure `appearance`
        // stays at its pre-reset value, and every draft below must reflect that
        // reality instead of asserting a reset that didn't actually land.
        draftGlowStrength = appearance.glowStrength
        draftFontSize = appearance.fontSize
        draftTextScale = appearance.uiTextScale
        // Cancel and resync directly rather than through a reactive signal: this
        // runs synchronously in the same call, so there's no window for the
        // debounced ColorPicker commit in TerminalBackgroundSettings.schedulePersist
        // to win a race against a SwiftUI onChange dispatch.
        pendingColorCommit?.cancel()
        draftColorHex = appearance.terminalBackgroundColor
        // Only announce success if the fields we just tried to reset actually landed.
        // `attemptPersist` writes the whole candidate config atomically — if it failed,
        // none of the fields above changed — so this check is equivalent to checking
        // the persist's own success, without `AppearanceStore.update` needing to expose
        // one. Skipping the announcement on failure matters here specifically: telling
        // VoiceOver "reset to defaults" when the disk write silently failed is worse
        // than saying nothing, since sighted users at least see the sliders not move.
        let didReset =
            appearance.theme == defaults.theme
            && appearance.accent == defaults.accent
            && appearance.uiFont == defaults.uiFont
            && appearance.monoFont == defaults.monoFont
            && appearance.fontSize == defaults.fontSize
            && appearance.uiTextScale == defaults.uiTextScale
            && appearance.glowStrength == defaults.glowStrength
            && appearance.terminalThemeID == defaults.terminalThemeID
            && appearance.terminalBackgroundMode == defaults.terminalBackgroundMode
            && appearance.terminalBackgroundColor == defaults.terminalBackgroundColor
            && appearance.alwaysShowJumpNumbers == defaults.alwaysShowJumpNumbers
            && appearance.sidebarPosition == defaults.sidebarPosition
            && appearance.crtScanlines == defaults.crtScanlines
        if didReset {
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: String(
                        localized: "Appearance settings reset to defaults.",
                        comment: "VoiceOver announcement after resetting the Appearance settings pane"),
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ]
            )
        }
    }
}

private struct TerminalFontSizeSlider: View {
    @Binding var draftValue: Double
    let commit: (Double) -> Void

    // UI floor is intentionally narrower than the runtime clamp in
    // `TerminalAppearancePreferences.ghosttyFontSize` (6...72). Sub-8pt is
    // practically unreadable in a terminal; >32pt belongs in a hand-edited
    // TOML, not a slider. Hand-edited values outside the slider range
    // survive disk round-trip but get snapped on first slider touch.
    private let range: ClosedRange<Double> = 8...32

    private var roundedValue: Int { Int(draftValue.rounded()) }

    var body: some View {
        HStack(spacing: 12) {
            Slider(
                value: $draftValue,
                in: range,
                step: 1,
                onEditingChanged: { editing in
                    if !editing { commit(draftValue) }
                }
            )
            .frame(maxWidth: 260)
            .accessibilityLabel("Terminal font size")
            .accessibilityValue(LocalizedPluralStrings.settingsFontSizePoints(count: roundedValue))
            .accessibilityHint("Updates open terminal panes without restarting their shell.")

            Text("\(roundedValue) pt")
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.text3)
                .monospacedDigit()
                .accessibilityHidden(true)
        }
    }
}

private struct InterfaceTextSizeSlider: View {
    @Binding var draftValue: Double
    let commit: (Double) -> Void

    private var percentText: String {
        draftValue.formatted(.percent.precision(.fractionLength(0)))
    }

    var body: some View {
        HStack(spacing: 12) {
            Slider(
                value: $draftValue,
                in: AwTextScale.range,
                step: 0.05,
                onEditingChanged: { editing in
                    if !editing { commit(draftValue) }
                }
            )
            .frame(maxWidth: 260)
            .accessibilityLabel(String(localized: "Interface text size", comment: "Accessibility label for the app UI text-size slider"))
            .accessibilityValue(percentText)
            .accessibilityHint(
                String(localized: "Scales sidebar, panel, and settings text.", comment: "Accessibility hint for the UI text-size slider"))

            Text(percentText)
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.text3)
                .monospacedDigit()
                .accessibilityHidden(true)
        }
    }
}

private struct TerminalBackgroundSettings: View {
    // Matches the TerminalAppearanceSync apply-path debounce. ColorPicker
    // has no `onEditingChanged`, so we can't mirror the slider commit
    // pattern — but a 75ms trailing debounce coalesces a drag (30-60Hz
    // value updates) into a single AppSettingsStore write. Without this,
    // every drag tick fires AppearanceStore.update → attemptPersist →
    // ConfigFileStore.save → atomic disk write (Codex flagged the disk
    // churn + UI jank).
    private static let persistDebounceMilliseconds: UInt64 = 75

    let theme: AppearanceConfig.Theme
    let terminalThemeID: String?
    @Binding var mode: AppearanceConfig.TerminalBackgroundMode
    @Binding var colorHex: String
    // Draft + debounce Task are owned by AppearanceSettingsPane (not local @State
    // here) so its resetToDefaults() can cancel the debounce and resync the draft
    // synchronously — see the comment on resetToDefaults() for why. Everything
    // else about the draft/debounce pattern is unchanged: the draft updates live
    // during a ColorPicker drag without committing every intermediate tick, and
    // commits to `colorHex` on a trailing debounce; preset clicks commit
    // immediately because they ARE the commit gesture, not a continuous drag.
    @Binding var draftColorHex: String
    @Binding var pendingCommit: Task<Void, Never>?

    @Environment(\.colorScheme) private var colorScheme

    private var effectiveCustomHex: String {
        draftColorHex.isEmpty ? colorHex : draftColorHex
    }

    private var previewHex: String {
        switch mode {
        case .ghostty, .catppuccinTheme:
            TerminalAppearancePreferences.terminalThemeCatalog
                .provider(for: terminalThemeID)
                .background(for: effectiveTheme)
        case .custom:
            effectiveCustomHex
        }
    }

    private var effectiveTheme: TerminalAppearancePreferences.EffectiveTheme {
        switch theme {
        case .light:
            .light
        case .dark:
            .dark
        case .system:
            colorScheme == .light ? .light : .dark
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Terminal background", selection: $mode) {
                Text("Ghostty").tag(AppearanceConfig.TerminalBackgroundMode.ghostty)
                Text("Catppuccin").tag(AppearanceConfig.TerminalBackgroundMode.catppuccinTheme)
                Text("awesoMux").tag(AppearanceConfig.TerminalBackgroundMode.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Terminal background source")
            .frame(maxWidth: .infinity, alignment: .leading)
            // Extra breathing room below the mode picker so it reads as a
            // distinct control above the preview/preset content, not crowded
            // against it. The VStack's 10pt is too tight for this break.
            .padding(.bottom, 4)

            if mode == .custom {
                Text("Start with a Catppuccin preset, then adjust the color if needed.")
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text3)

                TerminalBackgroundPresetGrid(selection: presetSelectionBinding)

                ColorPicker("Adjust background", selection: customColorBinding, supportsOpacity: false)
                    .frame(maxWidth: 280)
            }

            TerminalBackgroundPreview(backgroundHex: previewHex, usesGhosttyConfig: mode == .ghostty)
        }
        // draftColorHex's initial seed and its resync against external writes to
        // colorHex both live on AppearanceSettingsPane now — it owns the @State,
        // so it owns the .onAppear/.onChange that maintain it.
    }

    private var presetSelectionBinding: Binding<String> {
        // Preset clicks ARE commit gestures, not drag samples — write
        // straight through and update the draft so the live preview
        // stays in sync.
        Binding(
            get: { effectiveCustomHex },
            set: { newValue in
                pendingCommit?.cancel()
                draftColorHex = newValue
                colorHex = newValue
            }
        )
    }

    private var customColorBinding: Binding<Color> {
        // On the read side, fall back to the Catppuccin default base color
        // (not `.black`) so a transient invalid `colorHex` doesn't make the
        // ColorPicker show pure black — the user would then think they've
        // already lost their picked color and re-pick from black.
        let defaultBase =
            NSColor.awesoMuxSettingsHex(
                AppearanceConfig.defaultValue.terminalBackgroundColor
            ) ?? .black
        return Binding(
            get: { Color(nsColor: NSColor.awesoMuxSettingsHex(effectiveCustomHex) ?? defaultBase) },
            set: { color in
                // Pin to sRGB explicitly. Without this, a wide-gamut
                // ColorPicker pick can return component values outside
                // 0...1, which the hex formatter doesn't survive.
                let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? defaultBase
                guard let hex = nsColor.awesoMuxSettingsHexString else { return }
                draftColorHex = hex
                schedulePersist(hex)
            }
        )
    }

    private func schedulePersist(_ hex: String) {
        pendingCommit?.cancel()
        pendingCommit = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.persistDebounceMilliseconds * 1_000_000)
            if Task.isCancelled { return }
            if colorHex != hex {
                colorHex = hex
            }
        }
    }
}

private struct TerminalBackgroundPresetGrid: View {
    @Binding var selection: String

    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 34, maximum: 44), spacing: 10, alignment: .leading)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(TerminalAppearancePreferences.catppuccinBackgroundPresets, id: \.hex) { preset in
                let selected = selection.caseInsensitiveCompare(preset.hex) == .orderedSame
                Button {
                    selection = preset.hex
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color(nsColor: NSColor.awesoMuxSettingsHex(preset.hex) ?? .black))
                            .frame(width: 24, height: 24)
                        if selected {
                            Circle().stroke(Color.aw.text, lineWidth: 2).frame(width: 30, height: 30)
                        }
                    }
                    // Hit area is larger than the painted swatch so the
                    // 24pt visual circle still meets reasonable target-size
                    // affordance for motor-impaired and tremor users.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(preset.name) \(preset.hex)")
                .accessibilityLabel(preset.name)
                .accessibilityValue(preset.hex)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
    }
}

private struct TerminalBackgroundPreview: View {
    let backgroundHex: String
    let usesGhosttyConfig: Bool

    var body: some View {
        if usesGhosttyConfig {
            // In Ghostty-config mode awesoMux doesn't emit a background
            // override — the user's `~/.config/ghostty/config` controls
            // the actual color. Drawing a colored swatch here would lie
            // (we'd show Catppuccin Mocha while their Ghostty config may
            // be Solarized, Gruvbox, anything). Show a neutral badge
            // until awesoMux can read the resolved background from
            // libghostty — tracked in INT-285.
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .foregroundStyle(Color.aw.text2)
                    .accessibilityHidden(true)
                Text("Your Ghostty config controls the terminal background.")
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text2)
            }
            .padding(12)
            .frame(maxWidth: 420, alignment: .leading)
            .background(Color.aw.surface.elevated, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.aw.border2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Terminal background is controlled by your Ghostty configuration.")
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text("awesoMux color preview")
                    .foregroundStyle(Color.aw.text3)
                Text("\(Self.currentUserName)@awesoMux ~/project\n❯ codex --model gpt-5.5\n✓ background preview text")
                    .awFont(AwFont.Mono.body)
                    .foregroundStyle(foregroundColor)
                    .padding(12)
                    .frame(maxWidth: 420, alignment: .leading)
                    .background(backgroundColor, in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.aw.border2)
                    }
                    // The sample prompt is purely visual — speaking it
                    // aloud is noise for screen-reader users mid-form.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Preview of terminal background")
            }
        }
    }

    private var backgroundColor: Color {
        Color(nsColor: backgroundNSColor)
    }

    private var backgroundNSColor: NSColor {
        NSColor.awesoMuxSettingsHex(backgroundHex) ?? .black
    }

    // Derive foreground from background luminance instead of hardcoding
    // white — Latte presets (#eff1f5 etc.) are near-white, and white-on-
    // near-white text fails WCAG by a country mile and makes the preview
    // illegible at exactly the moment its job is to show readability.
    private var foregroundColor: Color {
        let srgb = backgroundNSColor.usingColorSpace(.sRGB) ?? backgroundNSColor
        let luminance =
            0.2126 * srgb.redComponent
            + 0.7152 * srgb.greenComponent
            + 0.0722 * srgb.blueComponent
        return luminance > 0.5
            ? Color.black.opacity(0.85)
            : Color.white.opacity(0.88)
    }

    private static var currentUserName: String {
        let name = NSUserName()
        return name.isEmpty ? "you" : name
    }
}

private struct GlowSlider: View {
    @Binding var draftValue: Double
    let commit: (Double) -> Void
    @Environment(\.awAccent) private var accentResolver

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Slider(
                    value: $draftValue,
                    in: 0...1,
                    step: 0.05,
                    onEditingChanged: { editing in
                        if !editing { commit(draftValue) }
                    }
                )
                .frame(maxWidth: 320)
                .accessibilityLabel("Glow strength")
                .accessibilityValue(draftValue.formatted(.percent.precision(.fractionLength(0))))

                Text(draftValue.formatted(.percent.precision(.fractionLength(0))))
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text3)
                    .monospacedDigit()
                    .accessibilityHidden(true)

                Circle()
                    .fill(Color.aw.accent(accentResolver.accent))
                    .frame(width: 14, height: 14)
                    .awGlow(
                        color: Color.aw.accentGlow(accentResolver.accent),
                        radius: 14
                    )
                    .awGlowStrength(draftValue)
                    .accessibilityHidden(true)
            }
        }
    }
}

private extension NSColor {
    static func awesoMuxSettingsHex(_ hex: String) -> NSColor? {
        guard let normalized = AppearanceConfig.normalizedTerminalBackgroundColor(hex),
            let value = UInt32(String(normalized.dropFirst()), radix: 16)
        else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    var awesoMuxSettingsHexString: String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        // Clamp explicitly to [0, 1]. SwiftUI's `ColorPicker` can hand
        // back extended-sRGB component values outside that range when the
        // user picks an out-of-sRGB-gamut color (vivid P3 picks on a
        // wide-gamut display). Without the clamp, the `Int(* 255)` step
        // produces negative or >255 values that the hex formatter
        // doesn't survive, persisting garbage to TOML.
        func clampedByte(_ component: CGFloat) -> Int {
            Int((min(max(component, 0), 1) * 255).rounded())
        }
        return String(
            format: "#%02x%02x%02x",
            clampedByte(rgb.redComponent),
            clampedByte(rgb.greenComponent),
            clampedByte(rgb.blueComponent)
        )
    }
}

private extension AwAccent {
    var configAccent: AppearanceConfig.Accent {
        switch self {
        case .peach: .peach
        case .mauve: .mauve
        case .sapphire: .sapphire
        case .green: .green
        }
    }
}
