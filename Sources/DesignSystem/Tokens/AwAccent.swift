import SwiftUI

/// Mirror of `AppearanceConfig.Accent` that lives in the design system so
/// `DesignSystem` does not need to import `AwesoMuxConfig`. String raw
/// values must stay in lockstep with the config enum's snake_case TOML
/// representation — `AppearanceBridge` is responsible for translating
/// between the two and is the only allowed bridge point.
public enum AwAccent: String, CaseIterable, Sendable {
    case peach
    case mauve
    case sapphire
    case green

    /// Catppuccin palette key driving this accent's color. Used by
    /// `AwColors.accent(_:)` to resolve a theme-aware color through the
    /// existing palette indirection.
    var paletteKey: KeyPath<AwPalette, String> {
        switch self {
        case .peach: \.peach
        case .mauve: \.mauve
        case .sapphire: \.sapphire
        case .green: \.green
        }
    }

    /// Human-facing display name for use in pickers and accessibility
    /// labels. Capitalised manually so the design-system layer doesn't
    /// drag in a localisation strategy yet.
    public var displayName: String {
        switch self {
        case .peach: "Peach"
        case .mauve: "Mauve"
        case .sapphire: "Sapphire"
        case .green: "Green"
        }
    }

    /// Muted, contrast-tuned divider tint as `(mocha, latte)` hex, resolved
    /// through `AwColors.dividerAccent(_:focused:)`.
    ///
    /// The bright accent palette can't be used directly for the pane divider:
    /// against the terminal `base`, several accents fall below the WCAG 1.4.11
    /// floor in Latte (peach 2.64:1, sapphire 2.78:1, green 2.96:1). These are
    /// heavily desaturated (~30% of the accent's saturation) and luminance-tuned
    /// to clear ≥3:1 at rest / ≥4:1 on hover in BOTH themes (~3.25 / ~4.1). The
    /// desaturation is deliberate: a full-strength accent line read as too vivid,
    /// so this lands as a near-gray line with only a whisper of the app accent —
    /// the subtle feel of the old neutral divider, without the OS-window-chrome
    /// character. Saturation is the taste dial here, not contrast (which stays
    /// pinned to the floor INT-299 set).
    ///
    /// Reference is the app theme `base`. The divider actually sits against the
    /// user's terminal background, which is independent of the app theme and
    /// (in Ghostty-config mode) not yet readable by awesoMux — INT-285. Until
    /// then the gap is killed structurally (the divider fills its layout
    /// channel, no pane-background sliver leaks) so a mismatched terminal bg
    /// no longer produces a visible seam.
    func dividerHex(focused: Bool) -> (mocha: String, latte: String) {
        switch (self, focused) {
        case (.peach, false):    ("#8c674f", "#a97b61")
        case (.peach, true):     ("#a1765b", "#966b51")
        case (.mauve, false):    ("#7f62a1", "#937bb1")
        case (.mauve, true):     ("#8e74ac", "#8369a6")
        case (.sapphire, false): ("#527483", "#618c94")
        case (.sapphire, true):  ("#5e8596", "#547b81")
        case (.green, false):    ("#587755", "#6c8e64")
        case (.green, true):     ("#658862", "#5e7c58")
        }
    }

    /// Vivid focus-accent variants as `(mocha, latte)` hex, fed to
    /// `AwColors.focusAccent(_:terminalBackground:)` for the active-pane stripe.
    ///
    /// Unlike `dividerHex` (deliberately desaturated, near-gray) these stay
    /// fully saturated — the stripe is the primary focus cue and must pop, not
    /// whisper. The `mocha` value is the bright palette accent for dark
    /// terminals (8–11:1 on `#1e1e2e`); the `latte` value darkens each hue for
    /// light terminals, where the raw bright accent collapses (peach 2.64:1,
    /// sapphire 2.78:1, green 2.96:1, below the WCAG 1.4.11 3:1 floor — the
    /// original light-mode-invisible bug). Both are tuned for the *extremes*;
    /// the picker handles the mid-tone gap between them with a neutral fallback
    /// (see `focusAccent`), so these two only have to nail dark and light.
    /// `AwColorTests` sweeps the floor across both poles and the mid-tone zone.
    /// See the divider-token rationale (INT-299) for the same asymmetry.
    func focusHex() -> (mocha: String, latte: String) {
        switch self {
        case .peach:    ("#fab387", "#b84200")
        case .mauve:    ("#cba6f7", "#8839ef")
        case .sapphire: ("#74c7ec", "#0b6f9e")
        case .green:    ("#a6e3a1", "#2a7d1c")
        }
    }

    /// Text-safe accent variants for small chrome wordmarks. Mocha keeps the
    /// standard bright accent; Latte darkens each hue enough to clear WCAG
    /// 1.4.3's 4.5:1 normal-text floor on chrome surfaces.
    func chromeTextHex() -> (mocha: String, latte: String, mochaHC: String, latteHC: String) {
        switch self {
        case .peach:    ("#fab387", "#a43d05", "#ffc8a3", "#9b3d07")
        case .mauve:    ("#cba6f7", "#7929e0", "#dcc2ff", "#6f20d1")
        case .sapphire: ("#74c7ec", "#086982", "#9ee4ff", "#00627d")
        case .green:    ("#a6e3a1", "#2b6c1e", "#c2f5bd", "#29661c")
        }
    }
}

/// Environment-resolved current accent. Phase A introduced this token
/// additively. Phase D flipped the bare `Color.aw.accent` getter to read
/// `AwAccentRuntime.current`, and views that need to re-render on accent
/// change should read `@Environment(\.awAccent)` and pass the value through
/// the explicit `Color.aw.accent(_:)` API.
// Equatable so SwiftUI can prove a same-value environment rewrite is a no-op
// for all \.awAccent readers, instead of relying on the reflection fallback.
public struct AwAccentResolver: Equatable, Sendable {
    public var accent: AwAccent

    public init(accent: AwAccent = .peach) {
        self.accent = accent
    }
}

/// Main-actor mailbox for the currently-resolved accent. Lives in the design
/// system so non-view code paths (`AttributedString.foregroundColor`,
/// `NSColor` consumers, anywhere a `Color` is needed outside a view body)
/// can resolve the accent without an environment. SwiftUI views should still
/// prefer `@Environment(\.awAccent)` so their bodies re-evaluate when the
/// accent changes — reading `AwAccentRuntime.current` from a view body does
/// not establish a SwiftUI dependency.
///
/// Written by `AppearanceBridge`; read by `AwColors.accent` / `accentSoft`
/// / `accentGlow` getters that take no argument.
@MainActor
public enum AwAccentRuntime {
    public static var current: AwAccent = .peach
}

private struct AwAccentResolverKey: EnvironmentKey {
    static let defaultValue = AwAccentResolver()
}

private struct AwGlowStrengthKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

public extension EnvironmentValues {
    /// The currently resolved accent. Defaults to `.peach` to match
    /// `AppearanceConfig.defaultValue.accent`.
    var awAccent: AwAccentResolver {
        get { self[AwAccentResolverKey.self] }
        set { self[AwAccentResolverKey.self] = newValue }
    }

    /// User-configured glow strength on `0.0 ... 1.0`. Consumed by
    /// `awGlow(...)` to scale halo radii. Defaults to `1.0` so views
    /// rendered outside the configured app (previews, tests) keep their
    /// nominal glow.
    var awGlowStrength: Double {
        get { self[AwGlowStrengthKey.self] }
        set { self[AwGlowStrengthKey.self] = newValue }
    }
}

public extension View {
    /// Inject the resolved accent into descendant views.
    func awAccent(_ accent: AwAccent) -> some View {
        environment(\.awAccent, AwAccentResolver(accent: accent))
    }

    /// Inject the resolved glow strength into descendant views.
    /// `strength` is clamped at consumption (see `AwGlowModifier`).
    func awGlowStrength(_ strength: Double) -> some View {
        environment(\.awGlowStrength, strength)
    }
}
