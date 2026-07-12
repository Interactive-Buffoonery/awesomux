import SwiftUI

public enum AwShadow: Sendable {
    case window
    case overlay
    case sheet
    case toast
    case findBar
    case handle

    /// Shadow radii strictly greater than this value are expensive to animate
    /// as live Core Animation drop shadows. `View.awShadow(_:)` applies those
    /// heavy shadows, then flattens the result with
    /// `compositingGroup().drawingGroup()` so large blurs can be rasterized with
    /// the shadowed layer instead of recomputed as a separate live effect.
    ///
    /// The trade-off is an offscreen render pass, so the threshold radius itself
    /// (for example `.overlay` at 16) and smaller tokens stay live to avoid
    /// unnecessary texture work.
    static let rasterizedRadiusThreshold: CGFloat = 16

    var radius: CGFloat {
        switch self {
        case .window:
            return 24
        case .overlay:
            return 16
        case .sheet:
            return 28
        case .toast:
            return 18
        case .findBar:
            return 14
        case .handle:
            return 8
        }
    }

    var y: CGFloat {
        switch self {
        case .window:
            return 18
        case .overlay, .findBar:
            return 10
        case .sheet:
            return 22
        case .toast:
            return 12
        case .handle:
            return 4
        }
    }

    var opacity: Double {
        switch self {
        case .window, .sheet:
            return 0.30
        case .overlay, .toast:
            return 0.24
        case .findBar:
            return 0.20
        case .handle:
            return 0.16
        }
    }
}

public enum AwShadowRendering: Sendable {
    case standard
    case composited
}

public extension View {
    func awShadow(_ awShadow: AwShadow, rendering: AwShadowRendering = .standard) -> some View {
        modifier(AwShadowModifier(shadow: awShadow, rendering: rendering))
    }

    /// Status / identity glow that respects `accessibilityReduceTransparency`.
    /// Drops the halo entirely under reduced-transparency so users who suppress
    /// vibrancy/blur effects in the OS don't get a residual colored aura.
    func awGlow(color: Color, radius: CGFloat, y: CGFloat = 0) -> some View {
        modifier(AwGlowModifier(color: color, radius: radius, y: y))
    }
}

private struct AwShadowModifier: ViewModifier {
    let shadow: AwShadow
    let rendering: AwShadowRendering
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
        } else if rendering == .composited {
            content
                .compositingGroup()
                .shadow(
                    color: shadow.color.opacity(shadow.opacity),
                    radius: shadow.radius,
                    x: 0,
                    y: shadow.y
                )
        } else if shadow.shouldRasterizeAnimatedShadow {
            content
                .shadow(
                    color: shadow.color.opacity(shadow.opacity),
                    radius: shadow.radius,
                    x: 0,
                    y: shadow.y
                )
                .compositingGroup()
                .drawingGroup()
        } else {
            content.shadow(
                color: shadow.color.opacity(shadow.opacity),
                radius: shadow.radius,
                x: 0,
                y: shadow.y
            )
        }
    }
}

private struct AwGlowModifier: ViewModifier {
    let color: Color
    let radius: CGFloat
    let y: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.awGlowStrength) private var glowStrength

    func body(content: Content) -> some View {
        // Glow is a soft identity cue. Under reduced transparency or increased
        // contrast, drop it — callers should communicate state through hard
        // strokes / color contrast instead.
        if reduceTransparency || contrast == .increased {
            content
        } else {
            // Clamp so a hand-edited TOML glow strength cannot blow geometry.
            let multiplier = CGFloat(min(max(glowStrength, 0.0), 1.0))
            if multiplier <= 0 {
                content
            } else {
                content.shadow(color: color, radius: radius * multiplier, x: 0, y: y)
            }
        }
    }
}

private extension AwShadow {
    var color: Color {
        Color.aw.surface.shadow
    }
}

extension AwShadow {
    var shouldRasterizeAnimatedShadow: Bool {
        radius > Self.rasterizedRadiusThreshold
    }
}
