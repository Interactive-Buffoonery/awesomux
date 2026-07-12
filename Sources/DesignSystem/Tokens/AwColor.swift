import AppKit
import SwiftUI

public extension Color {
    static let aw = AwColors()
}

public struct AwColors: Sendable {
    let mocha = AwPalette(
        rosewater: "#f5e0dc",
        flamingo: "#f2cdcd",
        pink: "#f5c2e7",
        mauve: "#cba6f7",
        red: "#f38ba8",
        maroon: "#eba0ac",
        peach: "#fab387",
        yellow: "#f9e2af",
        green: "#a6e3a1",
        teal: "#94e2d5",
        sky: "#89dceb",
        sapphire: "#74c7ec",
        blue: "#89b4fa",
        lavender: "#b4befe",
        text: "#cdd6f4",
        subtext1: "#bac2de",
        subtext0: "#a6adc8",
        overlay2: "#9399b2",
        overlay1: "#7f849c",
        overlay0: "#6c7086",
        surface2: "#585b70",
        surface1: "#45475a",
        surface0: "#313244",
        base: "#1e1e2e",
        mantle: "#181825",
        crust: "#11111b"
    )

    let latte = AwPalette(
        rosewater: "#dc8a78",
        flamingo: "#dd7878",
        pink: "#ea76cb",
        mauve: "#8839ef",
        red: "#d20f39",
        maroon: "#e64553",
        peach: "#fe640b",
        yellow: "#df8e1d",
        green: "#40a02b",
        teal: "#179299",
        sky: "#04a5e5",
        sapphire: "#209fb5",
        blue: "#1e66f5",
        lavender: "#7287fd",
        text: "#4c4f69",
        subtext1: "#5c5f77",
        subtext0: "#6c6f85",
        overlay2: "#7c7f93",
        overlay1: "#8c8fa1",
        overlay0: "#9ca0b0",
        surface2: "#acb0be",
        surface1: "#bcc0cc",
        surface0: "#ccd0da",
        base: "#eff1f5",
        mantle: "#e6e9ef",
        crust: "#dce0e8"
    )

    // Foreground rows (text → overlay0) are lightened from the standard mocha
    // ramp but kept stepped: each clears AA 4.5:1 against every same-theme
    // surface (tightest floor: `surface2 #585b70`). Locked by `AwColorTests`.
    let mochaHC = AwPalette(
        rosewater: "#fff0ed",
        flamingo: "#ffe0e0",
        pink: "#ffd6f0",
        mauve: "#dcc2ff",
        red: "#ffb3c4",
        maroon: "#ffc0c8",
        peach: "#ffc8a3",
        yellow: "#fff0c2",
        green: "#c2f5bd",
        teal: "#b0f4ea",
        sky: "#aeefff",
        sapphire: "#9ee4ff",
        blue: "#b7ccff",
        lavender: "#d0d8ff",
        text: "#ffffff",
        subtext1: "#f2f5ff",
        subtext0: "#e8edff",
        overlay2: "#dde4ff",
        overlay1: "#d5dcfb",
        overlay0: "#cdd6f4",
        surface2: "#585b70",
        surface1: "#45475a",
        surface0: "#313244",
        base: "#1e1e2e",
        mantle: "#181825",
        crust: "#11111b"
    )

    // Foreground rows (text → overlay0) are darkened from the standard latte
    // ramp but kept stepped: each clears AA 4.5:1 against every same-theme
    // surface (tightest floor: `surface2 #acb0be`; steps are compressed —
    // little luminance span fits between the AA floor and black). Locked by
    // `AwColorTests`.
    let latteHC = AwPalette(
        rosewater: "#963b31",
        flamingo: "#963737",
        pink: "#9a2d82",
        mauve: "#6f20d1",
        red: "#b00030",
        maroon: "#a82d37",
        peach: "#9b3d07",
        yellow: "#835100",
        green: "#29661c",
        teal: "#00685c",
        sky: "#0058a8",
        sapphire: "#00627d",
        blue: "#084fbd",
        lavender: "#354fb5",
        text: "#0a0a14",
        subtext1: "#15151f",
        subtext0: "#1e1e2e",
        overlay2: "#27273b",
        overlay1: "#303049",
        overlay0: "#3a3a55",
        surface2: "#acb0be",
        surface1: "#bcc0cc",
        surface0: "#ccd0da",
        base: "#eff1f5",
        mantle: "#e6e9ef",
        crust: "#dce0e8"
    )

    /// Resolved through `AwAccentRuntime.current` at view-body evaluation
    /// time. Views that must re-render on accent change should also observe
    /// `@Environment(\.awAccent)` so their body re-runs.
    @MainActor public var accent: Color { dynamic(AwAccentRuntime.current.paletteKey) }
    @MainActor public var accentOnChrome: Color { accentOnChrome(AwAccentRuntime.current) }
    @MainActor public var accentSoft: Color { dynamic(AwAccentRuntime.current.paletteKey).opacity(0.22) }
    @MainActor public var accentGlow: Color { dynamic(AwAccentRuntime.current.paletteKey).opacity(0.60) }

    /// Accent tokens for an explicit `AwAccent` — use from view code that
    /// already reads `@Environment(\.awAccent)`.
    public func accent(_ accent: AwAccent) -> Color { dynamic(accent.paletteKey) }
    public func accentOnChrome(_ accent: AwAccent) -> Color {
        let hex = accent.chromeTextHex()
        return Color(nsColor: NSColor.awDynamic(
            mocha: hex.mocha,
            latte: hex.latte,
            mochaHC: hex.mochaHC,
            latteHC: hex.latteHC
        ))
    }
    public func accentSoft(_ accent: AwAccent) -> Color { dynamic(accent.paletteKey).opacity(0.22) }
    public func accentGlow(_ accent: AwAccent) -> Color { dynamic(accent.paletteKey).opacity(0.60) }

    public var rosewater: Color { dynamic(\.rosewater) }
    public var flamingo: Color { dynamic(\.flamingo) }
    public var pink: Color { dynamic(\.pink) }
    public var mauve: Color { dynamic(\.mauve) }
    public var red: Color { dynamic(\.red) }
    public var maroon: Color { dynamic(\.maroon) }
    public var peach: Color { dynamic(\.peach) }
    public var yellow: Color { dynamic(\.yellow) }
    public var green: Color { dynamic(\.green) }
    public var teal: Color { dynamic(\.teal) }
    public var sky: Color { dynamic(\.sky) }
    public var sapphire: Color { dynamic(\.sapphire) }
    public var blue: Color { dynamic(\.blue) }
    public var lavender: Color { dynamic(\.lavender) }

    public var text: Color { dynamic(\.text) }
    public var text2: Color { dynamic(\.subtext0) }
    public var text3: Color { dynamic(\.overlay1) }
    public var textFaint: Color { dynamic(\.overlay0) }

    /// Secondary text drawn on the sidebar rail (`surface.sidebar` / mantle).
    /// Stock `text2` (subtext0) is only 4.06:1 against Latte mantle — below
    /// WCAG 1.4.3 AA. This token steps Latte to subtext1 (5.14:1) while Mocha
    /// and both HC palettes keep subtext0, which already clear AA with room.
    /// Live call sites: group header names, jump digits, pinned section chrome.
    /// See F44 / INT-480 follow-up.
    public var railText: Color {
        Color(nsColor: NSColor.awDynamic(
            mocha: mocha.subtext0,
            latte: latte.subtext1,
            mochaHC: mochaHC.subtext0,
            latteHC: latteHC.subtext0
        ))
    }

    public var border: Color { dynamic(\.text).opacity(0.08) }
    public var border2: Color { dynamic(\.text).opacity(0.14) }

    // Split-pane divider tokens: opaque per-theme values clearing WCAG 1.4.11
    // against `surface.terminal` in both themes — a single `text.opacity`
    // alpha cannot satisfy both. See INT-299.

    /// Divider at rest. Clears the 3:1 1.4.11 floor with added Latte
    /// headroom (Mocha 3.36, Latte 3.62).
    public var dividerRest: Color {
        Color(nsColor: NSColor.awDynamic(
            mocha: "#6c7086",
            latte: "#7a7c92",
            mochaHC: "#9399b2",
            latteHC: "#6c6f85"
        ))
    }

    /// Divider on hover / drag. Targets ~4:1 (Mocha 4.44, Latte 4.18).
    public var dividerHover: Color {
        Color(nsColor: NSColor.awDynamic(
            mocha: "#7f849c",
            latte: "#6f7288",
            mochaHC: "#a6adc8",
            latteHC: "#5c5f77"
        ))
    }

    /// Divider at rest under "Increase Contrast". Must stay equal to
    /// `dividerRest`'s HC slots; locked by `AwColorTests`.
    public var dividerRestHC: Color {
        Color(nsColor: NSColor.awDynamic(
            mocha: "#9399b2", latte: "#6c6f85",
            mochaHC: "#9399b2", latteHC: "#6c6f85"
        ))
    }

    /// Divider on hover / drag when the OS "Increase Contrast" setting is on.
    public var dividerHoverHC: Color {
        Color(nsColor: NSColor.awDynamic(
            mocha: "#a6adc8", latte: "#5c5f77",
            mochaHC: "#a6adc8", latteHC: "#5c5f77"
        ))
    }

    /// Workspace tint for the selected-row hairline border. Mocha keeps the
    /// bright accent; Latte uses darkened hexes (`AwTintAccent.latteBorderHex`)
    /// because the stock light accents miss WCAG 1.4.11's 3:1 floor as a
    /// border on `surface0`. Use `tint(_:)` for fills/glow. See INT-490.
    public func tintBorder(_ accent: AwTintAccent) -> Color {
        Color(nsColor: NSColor.awDynamic(mocha: mocha[keyPath: accent.paletteKey], latte: accent.latteBorderHex))
    }

    /// Workspace tint at full brightness in both themes — the group dot, the
    /// active rail, and the selection glow. For the border, use `tintBorder(_:)`.
    public func tint(_ accent: AwTintAccent) -> Color { dynamic(accent.paletteKey) }

    /// Opaque muted fill for a pane's colored title band when macOS Reduce
    /// Transparency is enabled. Each slot is the precomposited result of the
    /// normal 0.22 accent wash over chrome, preserving pane-color identity and
    /// contrast without leaving a translucent layer in the render tree.
    public func paneTitleBand(_ accent: AwTintAccent) -> Color {
        let hex = accent.paneTitleBandHex
        return Color(nsColor: NSColor.awDynamic(
            mocha: hex.mocha,
            latte: hex.latte,
            mochaHC: hex.mochaHC,
            latteHC: hex.latteHC
        ))
    }

    /// Muted accent divider for split panes. Holds the same 1.4.11 floor as
    /// the neutral tokens (≥3:1 rest / ≥4:1 hover vs the terminal `base`,
    /// both themes). Increased-contrast mode still uses
    /// `dividerRestHC`/`dividerHoverHC`. Per-accent values:
    /// `AwAccent.dividerHex`. See INT-299.
    public func dividerAccent(_ accent: AwAccent, focused: Bool) -> Color {
        let hex = accent.dividerHex(focused: focused)
        return Color(nsColor: NSColor.awDynamic(mocha: hex.mocha, latte: hex.latte))
    }

    /// Accent for the active-pane focus stripe. The stripe is drawn over the
    /// terminal surface, whose color is independent of app appearance
    /// (INT-285), so it can't key off the chrome: pick whichever `focusHex`
    /// variant (dark- or light-tuned) has higher WCAG contrast against the
    /// actual `terminalBackground`.
    public func focusAccent(_ accent: AwAccent, terminalBackground: Color) -> Color {
        let hex = accent.focusHex()
        let bright = NSColor.awHex(hex.mocha)
        let tuned = NSColor.awHex(hex.latte)
        let background = NSColor(terminalBackground).usingColorSpace(.sRGB)
            ?? NSColor.awHex("#1e1e2e")
        let brightContrast = awContrastRatio(bright, background)
        let tunedContrast = awContrastRatio(tuned, background)

        // On a mid-tone terminal both variants can miss the 3:1 floor, and
        // the stripe is the primary focus cue — fall back to black/white,
        // which always clears it.
        if max(brightContrast, tunedContrast) >= 3 {
            return Color(nsColor: brightContrast >= tunedContrast ? bright : tuned)
        }
        let white = NSColor.awHex("#ffffff")
        let black = NSColor.awHex("#000000")
        return awContrastRatio(white, background) >= awContrastRatio(black, background)
            ? Color(nsColor: white)
            : Color(nsColor: black)
    }

    /// Contrast-floor an arbitrary chrome color against the terminal
    /// background: unchanged if it clears 3:1, otherwise whichever of
    /// black/white reads better. `focusAccent`'s fallback for colors with no
    /// tuned `AwAccent` variant (e.g. the INT-223 drop-zone reject tint).
    public func contrastTuned(_ color: Color, terminalBackground: Color) -> Color {
        let foreground = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.awHex("#000000")
        let background = NSColor(terminalBackground).usingColorSpace(.sRGB)
            ?? NSColor.awHex("#1e1e2e")
        if awContrastRatio(foreground, background) >= 3 {
            return color
        }
        let white = NSColor.awHex("#ffffff")
        let black = NSColor.awHex("#000000")
        return awContrastRatio(white, background) >= awContrastRatio(black, background)
            ? Color(nsColor: white)
            : Color(nsColor: black)
    }

    /// Resolve an alpha-bearing overlay against an opaque design-system
    /// surface. Used when a caller needs the exact painted color as an opaque
    /// input for a second contrast or Reduce Transparency decision.
    public func composited(_ overlay: Color, over background: Color) -> Color {
        let overlay = NSColor(overlay).usingColorSpace(.sRGB)
            ?? NSColor.awHex("#000000")
        let background = NSColor(background).usingColorSpace(.sRGB)
            ?? NSColor.awHex("#1e1e2e")
        return Color(nsColor: overlay.awComposited(over: background))
    }

    /// Whether a background reads as dark by WCAG relative luminance. The
    /// 0.18 cut is the WCAG black-vs-white-text crossover.
    public func backgroundIsDark(_ color: Color) -> Bool {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.awHex("#1e1e2e")
        return awRelativeLuminance(resolved) < 0.18
    }

    public let status = Status()
    public let surface = Surface()

    public struct Status: Sendable {
        public static let tintOpacity = 0.18

        public var thinking: Color { Color.aw.dynamic(\.mauve) }

        // Latte darkened from stock peach: the stock value fails WCAG
        // 1.4.11's 3:1 floor as a StatusDot against sidebar chrome. See
        // INT-361.
        public var needs: Color {
            Color(nsColor: NSColor.awDynamic(
                mocha: "#fab387", latte: "#ad4001",
                mochaHC: "#ffc8a3", latteHC: "#9b3d07"
            ))
        }

        // Latte darkened from stock green — same 1.4.11 failure class as
        // `needs`. See INT-361.
        public var output: Color {
            Color(nsColor: NSColor.awDynamic(
                mocha: "#a6e3a1", latte: "#2d711f",
                mochaHC: "#c2f5bd", latteHC: "#29661c"
            ))
        }

        // MUST be paired with the pause glyph (INT-599): blue sits next to
        // `running`'s sapphire, so this token is not safe as a color-only
        // signal (tritanopia + adjacency).
        public var waiting: Color { Color.aw.dynamic(\.blue) }

        // Latte darkened from stock sapphire — same 1.4.11 failure class as
        // `needs`/`output`. Live via `AgentStatusBadge`'s full style. See
        // INT-361.
        public var running: Color {
            Color(nsColor: NSColor.awDynamic(
                mocha: "#74c7ec", latte: "#0a6d86",
                mochaHC: "#9ee4ff", latteHC: "#00627d"
            ))
        }

        // Deliberately faint — low contrast IS the idle signal. Latte fails
        // the 3:1 floor but is left alone: this token is unreachable in the
        // contrast-sensitive surfaces (INT-361 audit), and brightening it
        // would fight the design intent.
        public var idle: Color { Color.aw.dynamic(\.overlay0) }
        public var error: Color { Color.aw.dynamic(\.red) }

        // Latte darkened from stock teal — same 1.4.11 failure class as
        // `needs`/`output`. See INT-361.
        public var done: Color {
            Color(nsColor: NSColor.awDynamic(
                mocha: "#94e2d5", latte: "#116e74",
                mochaHC: "#b0f4ea", latteHC: "#00685c"
            ))
        }

        /// Backgrounded floating-panel work indicator on a sidebar session
        /// tile. The dot is the sole visual carrier for sighted users; the
        /// row accessibility label carries the same state for assistive
        /// technology. The dot must therefore clear WCAG 1.4.11's 3:1 floor
        /// against `surface.elevated`. Stock Latte teal
        /// sits at 2.43:1; Latte is darkened to the same value as `done`
        /// (shared teal-on-elevated failure class). See F44 / INT-480.
        public var floatingWork: Color {
            Color(nsColor: NSColor.awDynamic(
                mocha: "#94e2d5", latte: "#116e74",
                mochaHC: "#b0f4ea", latteHC: "#00685c"
            ))
        }

        public var onLoud: Color {
            // Readable foreground on a SOLID, opaque "loud" status fill.
            // Latte is white (not dark) because the darkened Latte fills
            // above dropped dark-on-fill text below WCAG's 4.5:1 text floor;
            // AA lock in `AwStateTests`. See INT-361.
            //
            // AwPill's loud-state tint does NOT use this token — its
            // translucent background is a different contrast relationship.
            // See `AwPill.loudTintForeground` in `StatusDot.swift`.
            Color(nsColor: NSColor.awDynamic(
                mocha: "#12121c", latte: "#ffffff",
                mochaHC: "#12121c", latteHC: "#ffffff"
            ))
        }

        public var onQuiet: Color {
            // Readable foreground for AwPill's quiet-state translucent tint
            // (not an opaque fill). Mirrors the theme `text` token; latteHC
            // flips to white since the dark latteHC text would collapse
            // against AwPill's tint.
            Color(nsColor: NSColor.awDynamic(
                mocha: Color.aw.mocha.text,
                latte: Color.aw.latte.text,
                mochaHC: Color.aw.mochaHC.text,
                latteHC: "#ffffff"
            ))
        }

        /// Opaque equivalent of a translucent status tint over its base
        /// surface. This preserves the tint's appearance when Reduce
        /// Transparency is enabled.
        public func tintBackground(
            for state: AwState,
            over baseSurface: Color,
            opacity: Double = Self.tintOpacity
        ) -> Color {
            let fill = NSColor(state.color).usingColorSpace(.sRGB)
                ?? NSColor.awHex("#000000")
            let base = NSColor(baseSurface).usingColorSpace(.sRGB)
                ?? NSColor.awHex("#1e1e2e")
            let composited = fill
                .withAlphaComponent(CGFloat(opacity))
                .awComposited(over: base)
            return Color(nsColor: composited)
        }

        /// Foreground for text and glyphs on a translucent status tint.
        /// Contrast is measured against the composited tint, not the opaque
        /// state color used by full status badges and buttons.
        public func tintForeground(
            for state: AwState,
            over baseSurface: Color,
            opacity: Double = Self.tintOpacity
        ) -> Color {
            let background = NSColor(tintBackground(
                for: state,
                over: baseSurface,
                opacity: opacity
            )).usingColorSpace(.sRGB) ?? NSColor.awHex("#1e1e2e")
            let preferred = NSColor(Color.aw.text).usingColorSpace(.sRGB)
                ?? NSColor.awHex("#ffffff")

            if awContrastRatio(preferred, background) >= 4.5 {
                return Color.aw.text
            }

            let white = NSColor.awHex("#ffffff")
            let black = NSColor.awHex("#000000")
            return awContrastRatio(white, background) >= awContrastRatio(black, background)
                ? Color(nsColor: white)
                : Color(nsColor: black)
        }
    }

    public struct Surface: Sendable {
        public var window: Color { Color.aw.dynamic(\.base) }
        public var chrome: Color { Color.aw.dynamic(\.mantle) }
        public var chrome2: Color { Color.aw.dynamic(\.crust) }
        public var sidebar: Color { Color.aw.dynamic(\.mantle) }
        public var terminal: Color { Color.aw.dynamic(\.base) }
        public var elevated: Color { Color.aw.dynamic(\.surface0) }
        public var hover: Color { Color.aw.dynamic(\.text).opacity(0.06) }
        public var active: Color { Color.aw.dynamic(\.text).opacity(0.10) }

        // Not catppuccin entries: latte = warm brown per the design handoff,
        // mocha = neutral black. Returned at full opacity — do not pass to
        // `.shadow(color:)` directly; route through `View.awShadow(_:)`.
        public var shadow: Color {
            Color(nsColor: NSColor.awDynamic(mocha: "#000000", latte: "#3c2814"))
        }
    }

    private func dynamic(_ keyPath: KeyPath<AwPalette, String>) -> Color {
        Color(nsColor: NSColor.awDynamic(
            mocha: mocha[keyPath: keyPath],
            latte: latte[keyPath: keyPath],
            mochaHC: mochaHC[keyPath: keyPath],
            latteHC: latteHC[keyPath: keyPath]
        ))
    }

    /// Light/dark only — the config-regeneration wiring tracks the effective
    /// light/dark theme, not "Increase Contrast", so there is no live hook to
    /// key an HC variant off of.
    public enum SearchHighlightColorScheme: Sendable {
        case light
        case dark
    }

    /// Raw hex pair for libghostty's `search-background` /
    /// `search-selected-background` config keys. The one sanctioned
    /// raw-palette escape hatch (`GhosttyConfigManager`) — kept narrow
    /// rather than exposing `AwPalette` generally.
    public func searchHighlightHex(
        theme: SearchHighlightColorScheme
    ) -> (background: String, selectedBackground: String) {
        let palette = theme == .dark ? mocha : latte
        return (background: palette.mauve, selectedBackground: palette.peach)
    }
}

/// Workspace tint accents. One identity resolves to both the bright
/// fill (`Color.aw.tint`) and the contrast-tuned border (`Color.aw.tintBorder`),
/// so the dot, rail, glow, and border can never drift to different hues.
public enum AwTintAccent: Sendable, CaseIterable, Hashable {
    case mauve, peach, green, teal, blue, pink, yellow, red, gray, sky, lavender

    var paletteKey: KeyPath<AwPalette, String> {
        switch self {
        case .mauve: \.mauve
        case .peach: \.peach
        case .green: \.green
        case .teal: \.teal
        case .blue: \.blue
        case .pink: \.pink
        case .yellow: \.yellow
        case .red: \.red
        case .gray: \.subtext0
        case .sky: \.sky
        case .lavender: \.lavender
        }
    }

    /// Darkened Latte border variant, derived to clear ≥3.25:1 against
    /// `surface0` and ≥4.1:1 against `mantle`. Mocha needs no variant — see
    /// `AwColors.tintBorder(_:)`.
    var latteBorderHex: String {
        switch self {
        case .mauve: "#8839ef"
        case .peach: "#c14701"
        case .green: "#327e22"
        case .teal: "#137b81"
        case .blue: "#084fbd"
        case .pink: "#c91f9c"
        case .yellow: "#835100"
        case .red: "#b00030"
        case .gray: "#5c5f77"
        case .sky: "#0376a4"
        case .lavender: "#405cfc"
        }
    }

    var paneTitleBandHex: (mocha: String, latte: String, mochaHC: String, latteHC: String) {
        switch self {
        case .mauve: ("#3f3753", "#d1c2ef", "#433d55", "#ccbde8")
        case .peach: ("#4a3a3b", "#ebccbd", "#4b3f41", "#d6c3bc")
        case .green: ("#374540", "#c1d9c4", "#3d4946", "#bcccc1")
        case .teal: ("#33444c", "#b8d6dc", "#394850", "#b3cdcf")
        case .blue: ("#313a54", "#baccf0", "#3b4055", "#b5c7e4")
        case .pink: ("#493d50", "#e7d0e7", "#4b4252", "#d5c0d7")
        case .yellow: ("#4a4443", "#e4d5c1", "#4b4848", "#d0c8ba")
        case .red: ("#483142", "#e2b9c7", "#4b3a48", "#dab6c5")
        case .gray: ("#373949", "#cbced8", "#464755", "#babcc5")
        case .sky: ("#314351", "#b4daed", "#394755", "#b3c9df")
        case .lavender: ("#3a3d55", "#ccd3f2", "#404255", "#bfc7e2")
        }
    }
}

struct AwPalette: Sendable {
    let rosewater: String
    let flamingo: String
    let pink: String
    let mauve: String
    let red: String
    let maroon: String
    let peach: String
    let yellow: String
    let green: String
    let teal: String
    let sky: String
    let sapphire: String
    let blue: String
    let lavender: String
    let text: String
    let subtext1: String
    let subtext0: String
    let overlay2: String
    let overlay1: String
    let overlay0: String
    let surface2: String
    let surface1: String
    let surface0: String
    let base: String
    let mantle: String
    let crust: String
}

extension NSColor {
    fileprivate func awComposited(over background: NSColor) -> NSColor {
        let backgroundAlpha = background.alphaComponent
        let outputAlpha = alphaComponent + backgroundAlpha * (1 - alphaComponent)
        guard outputAlpha > 0 else { return .clear }

        func blend(_ foreground: CGFloat, _ background: CGFloat) -> CGFloat {
            (foreground * alphaComponent
                + background * backgroundAlpha * (1 - alphaComponent)) / outputAlpha
        }

        return NSColor(
            srgbRed: blend(redComponent, background.redComponent),
            green: blend(greenComponent, background.greenComponent),
            blue: blend(blueComponent, background.blueComponent),
            alpha: outputAlpha
        )
    }

    /// Keyed on a struct, not a joined string, so cache hits allocate
    /// nothing. Components are lowercased before keying so differently-cased
    /// but visually identical hexes share an entry.
    private struct AwDynamicKey: Hashable {
        let mocha: String
        let latte: String
        let mochaHC: String
        let latteHC: String
    }

    /// Every access must hold `awDynamicCacheLock`. Unbounded by type but
    /// bounded in practice: all callers pass palette-table literals or hexes
    /// from finite enums. A future call site feeding a computed hex (e.g. a
    /// user-customizable accent) would silently grow the cache.
    ///
    /// The dictionary — not `NSColor(name:)` — is what gives identity
    /// stability (`===` across calls, stable `Color(nsColor:)` identity for
    /// SwiftUI). The `name:` exists only for debug dumps.
    private static let awDynamicCacheLock = NSLock()
    nonisolated(unsafe) private static var awDynamicCache: [AwDynamicKey: NSColor] = [:]

    static func awDynamic(mocha: String, latte: String) -> NSColor {
        awDynamic(mocha: mocha, latte: latte, mochaHC: mocha, latteHC: latte)
    }

    static func awDynamic(
        mocha: String,
        latte: String,
        mochaHC: String,
        latteHC: String
    ) -> NSColor {
        let key = AwDynamicKey(
            mocha: mocha.lowercased(),
            latte: latte.lowercased(),
            mochaHC: mochaHC.lowercased(),
            latteHC: latteHC.lowercased()
        )

        awDynamicCacheLock.lock()
        defer { awDynamicCacheLock.unlock() }
        if let cached = awDynamicCache[key] {
            return cached
        }

        // Built from `key`'s lowercased components (deterministic regardless
        // of caller casing); components never contain "-", so the joined
        // name can't collide across tuples.
        let name = "awDynamic-\(key.mocha)-\(key.latte)-\(key.mochaHC)-\(key.latteHC)"

        // The lock is held across NSColor construction and `NSLock` is not
        // reentrant — the dynamicProvider closure must never touch the cache
        // or the lock. If a future deadlock traces back here, re-examine the
        // assumption that AppKit's name-registration path doesn't call back
        // into application code.
        let color = NSColor(name: name) { appearance in
            let match = appearance.bestMatch(from: [
                .accessibilityHighContrastAqua,
                .accessibilityHighContrastDarkAqua,
                .aqua,
                .darkAqua,
            ])
            let hex = awDynamicHex(
                for: match,
                mocha: mocha,
                latte: latte,
                mochaHC: mochaHC,
                latteHC: latteHC
            )
            return NSColor.awHex(hex)
        }
        awDynamicCache[key] = color
        return color
    }

    static func awDynamicHex(
        for match: NSAppearance.Name?,
        mocha: String,
        latte: String,
        mochaHC: String,
        latteHC: String
    ) -> String {
        switch match {
        case .accessibilityHighContrastAqua:
            latteHC
        case .accessibilityHighContrastDarkAqua:
            mochaHC
        case .aqua:
            latte
        case .darkAqua:
            mocha
        default:
            mocha
        }
    }

    static func awHex(_ hex: String) -> NSColor {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6,
              let value = UInt32(trimmed, radix: 16) else {
            assertionFailure("AwColor: invalid hex string '\(hex)'")
            return .systemPink
        }

        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

/// WCAG relative luminance from a color's sRGB components.
// `AwColorTests` deliberately keeps its OWN copy of this math — an
// independent oracle catches a formula bug a shared impl would hide. Keep the
// two in sync by hand if the WCAG formula ever changes.
private func awRelativeLuminance(_ color: NSColor) -> Double {
    // Fall back to a known-RGB color: reading `.redComponent` off a non-RGB
    // NSColor throws an ObjC exception.
    let srgb = color.usingColorSpace(.sRGB) ?? NSColor.awHex("#1e1e2e")
    func linearize(_ channel: CGFloat) -> Double {
        let v = Double(channel)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linearize(srgb.redComponent)
        + 0.7152 * linearize(srgb.greenComponent)
        + 0.0722 * linearize(srgb.blueComponent)
}

/// WCAG contrast ratio `(L_hi + 0.05) / (L_lo + 0.05)`.
private func awContrastRatio(_ a: NSColor, _ b: NSColor) -> Double {
    let la = awRelativeLuminance(a)
    let lb = awRelativeLuminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}
