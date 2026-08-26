import AppKit
import AwesoMuxConfig
import DesignSystem
import SwiftUI

/// Bridges user-configured appearance into the design system's runtime
/// resolvers and the SwiftUI environment.
///
/// Two channels share the same source of truth (`AppearanceConfig`):
///
/// 1. `AwAccentRuntime.current` — main-actor mailbox read by the bare
///    `Color.aw.accent` / `accentSoft` / `accentGlow` getters. Updated here
///    so non-view callers (`AttributedString.foregroundColor`, `NSColor`
///    consumers) see the configured accent without rewiring their plumbing.
///
/// 2. `\.awAccent` / `\.awGlowStrength` environment values — read by views
///    that need their bodies to re-evaluate when the accent or glow
///    strength changes. The modifier writes these on every body
///    evaluation so SwiftUI's diff propagates the new values down the tree.
///
/// Install once at the top of the main window's view tree via
/// `.appearanceBridge(appSettingsStore)`. Subsequent reads of
/// `\.awAccent` and `\.awGlowStrength` in descendant views resolve against
/// the user's config.
struct AppearanceBridge: ViewModifier {
    let appSettingsStore: AppSettingsStore

    /// Held so a later theme change can reach the window, not just the first
    /// attach — `WindowAccessor` fires only on `viewDidMoveToWindow`.
    @State private var hostWindow: NSWindow?

    func body(content: Content) -> some View {
        // Depend only on the appearance section so accent/theme/glow
        // changes don't have to ride through the whole-config invalidation
        // path. Sidebar/workspace/notification edits no longer cause this
        // bridge's body to re-evaluate.
        //
        // AwAccentRuntime.current is owned by the AppSettingsStore via
        // `syncAwAccentRuntime` so there's exactly one writer per
        // accent change — even when AppearanceBridge is installed in
        // multiple windows (main scene, QuickSettingsSheet,
        // Settings scene). Previously each install fired its own
        // `.task` write, which was benign at steady state but
        // racy under any future per-window accent override.
        let appearance = appSettingsStore.appearance.value
        let accent = AwAccent(configAccent: appearance.accent)

        content
            .environment(\.awAccent, AwAccentResolver(accent: accent))
            .environment(\.awGlowStrength, appearance.glowStrength)
            // Resolve the configured UI font family into the environment so the
            // `awFont` modifier renders it, falling back safely when it's
            // "system", not installed, or not proportional (INT-367).
            .environment(\.awUIFont, AwUIFontResolver.resolvedForSystem(rawFamily: appearance.uiFont))
            // Drive chrome text scaling (INT-237): the continuous user factor
            // that every `awFont` call site multiplies into its scaled size.
            .awTextScale(appearance.uiTextScale)
            // Theme rides the bridge rather than each scene, because a
            // detached NSHostingView (every FloatingSwiftUIPanelWindow root,
            // and the Settings scene) inherits the SYSTEM appearance, not the
            // main window's `.preferredColorScheme`. Those diverge for anyone
            // whose in-app theme differs from their system theme, which showed
            // up as a dark welcome tour floating over a light app.
            .preferredColorScheme(appearance.theme.colorScheme)
            // `.preferredColorScheme(nil)` does not clear an NSWindow override
            // SwiftUI already installed for a concrete scheme, so going Latte
            // -> System left the window pinned light while the system was dark.
            // Asserting the desired state is idempotent: a no-op when nothing
            // was stuck, and the un-stick when something was.
            .background(WindowAccessor { hostWindow = $0 })
            .onChange(of: appearance.theme) { _, _ in
                syncWindowAppearance(appearance.theme.colorScheme)
            }
            .onAppear { syncWindowAppearance(appearance.theme.colorScheme) }
    }
}

extension AppearanceBridge {
    @MainActor
    fileprivate func syncWindowAppearance(_ scheme: ColorScheme?) {
        guard let hostWindow else { return }
        switch scheme {
        case .none: hostWindow.appearance = nil
        case .dark: hostWindow.appearance = NSAppearance(named: .darkAqua)
        case .light: hostWindow.appearance = NSAppearance(named: .aqua)
        @unknown default: hostWindow.appearance = nil
        }
    }
}

extension AwUIFontResolver {
    /// Build a resolver from a raw `appearance.ui_font` value using the cached
    /// installed-proportional-family index. Kept in the app target so
    /// `DesignSystem` stays AppKit-agnostic; `DesignSystem` owns the fallback
    /// policy (`init(rawFamily:canonicalFamily:)`), this only supplies the probe.
    ///
    /// The match is case-insensitive and returns the catalog's own spelling:
    /// `Font.custom`/`NSFontManager` resolve family names case-insensitively, so
    /// a hand-edited `ui_font = "helvetica neue"` must render Helvetica Neue —
    /// and the picker must label it as installed — not silently fall back.
    @MainActor
    static func resolvedForSystem(rawFamily: String) -> AwUIFontResolver {
        let index = SettingsFontFamily.proportionalFamilyIndex()
        return AwUIFontResolver(rawFamily: rawFamily) { index[$0.lowercased()] }
    }
}

extension View {
    /// Wires `AppSettingsStore.appearance` into the design-system runtime
    /// mailbox (`AwAccentRuntime`) and into the SwiftUI environment values
    /// `\.awAccent` and `\.awGlowStrength`. Install once near the root of
    /// each window's view tree.
    func appearanceBridge(_ appSettingsStore: AppSettingsStore) -> some View {
        modifier(AppearanceBridge(appSettingsStore: appSettingsStore))
    }
}

extension AwAccent {
    init(configAccent: AppearanceConfig.Accent) {
        switch configAccent {
        case .peach: self = .peach
        case .mauve: self = .mauve
        case .sapphire: self = .sapphire
        case .green: self = .green
        }
    }
}
