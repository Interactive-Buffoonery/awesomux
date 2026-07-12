import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import SwiftUI

/// Visual-only retro scanlines drawn above the libghostty surface. Pure
/// SwiftUI overlay — no impact on input routing or PTY sizing because
/// `allowsHitTesting(false)` keeps clicks and key events passing through to
/// the surface beneath. Suppressed under `accessibilityReduceTransparency`
/// to honour users who disable decorative effects system-wide.
///
/// Implementation: a 1×4pt NSImage with one dark stripe is built once
/// process-wide and tiled via `Image.resizable(resizingMode: .tile)`. The
/// previous implementation used a `Canvas` with a `while` loop that
/// drew N fills per render — at typical pane heights of ~1200pt with a
/// 4pt stride that was 300 fill ops per render, and the Canvas
/// re-rendered on every GeometryReader size proposal (every drag of a
/// split divider). The tile pattern is GPU-composited and costs a
/// single texture sample regardless of pane size.
struct CRTScanlinesOverlay: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private static let scanlineTile: NSImage = {
        let tile = NSImage(size: NSSize(width: 1, height: 4))
        tile.lockFocus()
        NSColor.black.withAlphaComponent(0.08).setFill()
        NSRect(x: 0, y: 0, width: 1, height: 2).fill()
        tile.unlockFocus()
        return tile
    }()

    var body: some View {
        if reduceTransparency {
            EmptyView()
        } else {
            Image(nsImage: Self.scanlineTile)
                .resizable(resizingMode: .tile)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

struct PaneFocusAccent: View {
    /// Constant height of the focus-indicator band the title bar reserves on
    /// every pane (focused or not) so the bar can't bounce vertically when focus
    /// moves. Matches the resting dark-terminal stripe thickness — the common
    /// case; light/DWC stripes differ by ~1-2px, a negligible gap/bleed.
    static let reservedHeight: CGFloat = 4

    let state: AwState
    let differentiateWithoutColor: Bool
    @Environment(AppSettingsStore.self) private var appSettingsStore
    @Environment(\.awAccent) private var accentResolver
    @Environment(\.terminalBackgroundColor) private var terminalBackground

    private var isCursorGlowEnabled: Bool {
        appSettingsStore.appearance.value.cursorGlow
    }

    var body: some View {
        let isNeeds = state == .needs
        let accentColor = PaneFocusStyle.color(
            for: state,
            accent: accentResolver.accent,
            terminalBackground: terminalBackground
        )
        // Needs has to out-shout a normal focus rail even when the user's
        // chosen accent IS peach (the default) — same hue, so the difference
        // has to come from weight, not color. It gets extra heft plus a halo
        // that ignores the decorative cursor-glow *toggle* (radius 8 either
        // way), standing in for the busier 4-side border this replaced
        // (INT-111). The thickness bump — not the halo — is the robust cue:
        // awGlow still drops the halo under Reduce Transparency / Increase
        // Contrast / glow-strength 0, so the extra pixels carry the signal
        // when the glow can't.
        let baseThickness = PaneFocusStyle.thickness(
            differentiateWithoutColor: differentiateWithoutColor,
            terminalIsDark: Color.aw.backgroundIsDark(terminalBackground)
        )
        let thickness = isNeeds ? baseThickness + 3 : baseThickness
        // OFF means actually off — radius 0 disables the halo. `.needs` keeps a
        // fixed escalation halo regardless of the decorative cursor-glow toggle.
        let glowRadius: CGFloat = isNeeds
            ? PaneFocusStyle.needsGlowRadius
            : (isCursorGlowEnabled
                ? PaneFocusStyle.baseGlowRadius * PaneFocusStyle.cursorGlowMultiplier
                : 0)
        Rectangle()
            .fill(accentColor)
            .frame(height: thickness)
            .awGlow(
                color: accentColor.opacity(0.65),
                radius: glowRadius
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Darkens an inactive (non-focused) split pane so the active surface stands
/// out. Paired with the brighter focus stripe, this is the familiar
/// terminal-multiplexer "where am I" cue — dim the panes you're not in —
/// pushed a bit harder so it actually registers at a glance.
///
/// This is an additive scrim composited *above* the libghostty surface — a
/// plain source-over blend of one solid layer. It is deliberately NOT a
/// `.opacity` / `.saturation` applied to the host layer: that was tried and
/// rejected (PR #62, see `FloatingPanelView`) because a filter on the parent
/// of the Metal sublayer forces an offscreen flatten-and-recomposite every
/// frame the surface draws. An overlay sibling layer carries the same visual
/// recede for a single extra blend, with no offscreen pass — so a background
/// agent streaming output into an inactive pane stays cheap.
struct InactivePaneScrim: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    // Tuning dial. Higher = more dramatic. Black reads as "recede" in both
    // themes (darkens in Mocha, greys toward disabled in Latte). Softened
    // under Reduce Transparency since a translucent veil is exactly what that
    // setting asks to dial back — the focus stripe still carries the signal.
    private static let dimOpacity: Double = 0.32
    private static let reducedDimOpacity: Double = 0.14

    var body: some View {
        Rectangle()
            .fill(Color.black)
            .opacity(reduceTransparency ? Self.reducedDimOpacity : Self.dimOpacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

enum PaneFocusStyle {
    /// Decorative glow radius for a normal focus rail, scaled by
    /// `cursorGlowMultiplier` when the cursor-glow setting is on (0 when off).
    static let baseGlowRadius: CGFloat = 5
    static let cursorGlowMultiplier: CGFloat = 1.6
    /// Fixed escalation halo for `.needs`, independent of the decorative
    /// cursor-glow toggle. It happens to equal `baseGlowRadius * multiplier`,
    /// but the two are conceptually separate — keep them named so the
    /// coincidence doesn't read as intent.
    static let needsGlowRadius: CGFloat = 8

    static func color(
        for state: AwState,
        accent: AwAccent,
        terminalBackground: Color
    ) -> Color {
        // `focusAccent` picks the variant with the best contrast against the
        // actual terminal background — the raw accent dropped below the WCAG
        // floor on a light surface (peach 2.64:1), and the chrome-keyed variant
        // is wrong when the app theme and terminal background disagree (INT-285).
        // `.needs` forces peach (the status hue) through the same path so an
        // attention stripe stays legible on any terminal.
        let resolved: AwAccent = state == .needs ? .peach : accent
        return Color.aw.focusAccent(resolved, terminalBackground: terminalBackground)
    }

    static func thickness(
        differentiateWithoutColor: Bool,
        terminalIsDark: Bool
    ) -> CGFloat {
        // The old 2pt hairline read as invisible — a focus cue has to register
        // at a glance. Keyed off the *terminal* background (where the stripe
        // sits), not the app chrome: a dark terminal swallows a thin line so it
        // gets extra heft, a light one needs a touch less since the tuned color
        // already pops. DWC is the accessibility max, clearly above both.
        if differentiateWithoutColor { return 6 }
        return terminalIsDark ? 4 : 3
    }
}
