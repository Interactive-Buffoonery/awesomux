import Foundation
import SwiftUI

public enum AwAgentIcon: Sendable, Equatable, Hashable {
    case claude
    case codex
    case openCode
    case pi
    case grok
    case shell
}

public struct AgentTile: View, Equatable {
    public enum BadgeStyle: Sendable, Equatable {
        case full      // glyph-per-state except idle, which has no badge
        case collapsed // dot-only except needs/error; no badge when idle
    }

    private let agent: AwAgentIcon
    private let state: AwState
    private let size: CGFloat
    private let badgeStyle: BadgeStyle

    public init(agent: AwAgentIcon, state: AwState, size: CGFloat = 32, badgeStyle: BadgeStyle = .full) {
        self.agent = agent
        self.state = state
        self.size = size
        self.badgeStyle = badgeStyle
    }

    // Equatable conformance lets SwiftUI skip re-rendering identical tiles when
    // an unrelated session updates — the dominant sidebar perf win at scale.
    // `nonisolated` because Equatable.== is not main-actor; the compared fields
    // are all value-type Sendable.
    public nonisolated static func == (lhs: AgentTile, rhs: AgentTile) -> Bool {
        lhs.agent == rhs.agent && lhs.state == rhs.state && lhs.size == rhs.size && lhs.badgeStyle == rhs.badgeStyle
    }

    public var body: some View {
        tileBody
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityLabel(agent: agent, state: state))
    }

    public static func accessibilityLabel(
        agent: AwAgentIcon,
        state: AwState,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        let agent = agent.localizedAccessibilityName(bundle: bundle, locale: locale)
        let state = state.localizedLabel(bundle: bundle, locale: locale)
        let format = String(
            localized: "%1$@, %2$@",
            bundle: bundle,
            locale: locale,
            comment: "VoiceOver label for an agent tile. Arguments are the agent name and state."
        )
        return String(format: format, locale: locale, arguments: [agent, state])
    }

    public nonisolated static func showsStatusBadge(for state: AwState, style: BadgeStyle) -> Bool {
        switch style {
        case .full:
            state != .idle
        case .collapsed:
            CollapsedStatusBadge.resolve(for: state) != nil
        }
    }

    @ViewBuilder
    private var tileBody: some View {
        switch badgeStyle {
        case .full:
            // Expanded rows / peek card: the badge overflows into a 5pt
            // bottom-right margin via a top-left-pinned frame. The icon sits at
            // the row's leading edge so the asymmetry is invisible there.
            ZStack(alignment: .bottomTrailing) {
                tileSquare
                if Self.showsStatusBadge(for: state, style: badgeStyle) {
                    AgentStatusBadge(state, style: badgeStyle)
                        .offset(x: 3, y: 3)
                }
            }
            .frame(width: size + 5, height: size + 5, alignment: .topLeading)
        case .collapsed:
            // Collapsed rail: the tile fills its own size×size footprint so it
            // sits CONCENTRIC with the row's centered selection border. The badge
            // tucks INWARD (negative offset) so it overlaps the tile's straight-
            // edge fill rather than floating over the rounded-corner notch /
            // poking past the 40pt rail edge — the outward `+1,+1` read as a
            // clipped badge hanging off the corner.
            ZStack(alignment: .bottomTrailing) {
                tileSquare
                if Self.showsStatusBadge(for: state, style: badgeStyle) {
                    AgentStatusBadge(state, style: badgeStyle)
                        .offset(x: -2, y: -2)
                }
            }
            .frame(width: size, height: size)
        }
    }

    private var tileSquare: some View {
        RoundedRectangle(cornerRadius: size * 0.22)
            .fill(tileFill)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.22)
                    .stroke(Color.black.opacity(0.15), lineWidth: 0.5)
            }
            .frame(width: size, height: size)
            .overlay {
                glyph
            }
    }

    // Uniform tile for every agent: identity is carried by the glyph shape +
    // its hue, not by a per-agent background. (Claude previously had a peach
    // tile; the peach moved into the burst glyph so the set reads as a family.)
    private var tileFill: Color {
        Color.aw.surface.elevated
    }

    // Shared stroke for every drawn glyph — the family rule that makes five
    // marks read as one set. Scales with tile size so 18/32/48px stay balanced.
    private var glyphStroke: StrokeStyle {
        StrokeStyle(lineWidth: size * 0.053, lineCap: .round, lineJoin: .round)
    }

    @ViewBuilder
    private var glyph: some View {
        switch agent {
        case .claude:
            ClaudeGlyph()
                .foregroundStyle(Color.aw.peach)
                .frame(width: size * 0.55, height: size * 0.55)
        case .codex:
            CodexGlyph()
                .stroke(Color.aw.lavender, style: glyphStroke)
                .frame(width: size * 0.55, height: size * 0.55)
        case .openCode:
            OpenCodeGlyph()
                .stroke(Color.aw.sky, style: glyphStroke)
                .frame(width: size * 0.55, height: size * 0.55)
        case .pi:
            Text(verbatim: "π")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(Color.aw.mauve)
        case .grok:
            GrokGlyph()
                .stroke(Color.aw.green, style: glyphStroke)
                .frame(width: size * 0.55, height: size * 0.55)
        case .shell:
            ShellGlyph()
                .stroke(Color.aw.text, style: glyphStroke)
                .frame(width: size * 0.52, height: size * 0.52)
        }
    }
}

private struct AgentStatusBadge: View {
    private let state: AwState
    private let style: AgentTile.BadgeStyle

    init(_ state: AwState, style: AgentTile.BadgeStyle = .full) {
        self.state = state
        self.style = style
    }

    var body: some View {
        Group {
            switch style {
            case .full:
                fullBadge
            case .collapsed:
                collapsedBadge
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Full badge (expanded rows, peek card)

    @ViewBuilder
    private var fullBadge: some View {
        ZStack {
            Circle()
                .fill(background)
                .overlay {
                    Circle()
                        .stroke(Color.aw.surface.sidebar, lineWidth: 1.5)
                }
                .frame(width: 14, height: 14)

            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let glyph = AwStateGlyph.resolve(for: state)
        switch glyph {
        case .attention:
            Text(glyph.text ?? "")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(glyph.badgeForeground)
        case .error:
            Text(glyph.text ?? "")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(glyph.badgeForeground)
        case .checkmark:
            Image(systemName: "checkmark")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(glyph.badgeForeground)
        case .outputDot:
            Circle()
                .fill(glyph.badgeForeground)
                .frame(width: 5, height: 5)
        case .pause:
            // Pause bars — quiet "waiting for your next turn" (INT-599;
            // replaced the block-cursor bar that read as a blinking
            // cursor/eye). Two vertical bars stay distinct from `.play`'s
            // triangle for color-blind users (see AwStateGlyph.text).
            Image(systemName: "pause.fill")
                .font(.system(size: 6, weight: .bold))
                .foregroundStyle(glyph.badgeForeground)
        case .play:
            // `running`'s solid fill (`Color.aw.status.running`) holds the
            // same 3:1 WCAG 1.4.11 non-text floor `onLoud` already
            // guarantees for every other solid-fill state — `onQuiet`
            // collapsed to 1.31:1 in mocha (functionally invisible). Same
            // fix class as `waiting`'s sky→blue swap, INT-331. See INT-361.
            Image(systemName: "play.fill")
                .font(.system(size: 6, weight: .bold))
                .foregroundStyle(glyph.badgeForeground)
        case .spinner:
            Circle()
                .trim(from: 0.18, to: 1)
                .stroke(glyph.badgeForeground, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .frame(width: 8, height: 8)
        case .dot:
            Circle()
                .fill(glyph.badgeForeground)
                .frame(width: 4.5, height: 4.5)
        }
    }

    private var background: Color {
        switch state {
        case .needs:
            Color.aw.status.needs
        case .error:
            Color.aw.status.error
        case .done:
            Color.aw.status.done
        case .output:
            Color.aw.status.output
        case .waiting:
            Color.aw.status.waiting
        case .running:
            Color.aw.status.running
        case .thinking:
            Color.aw.surface.chrome2
        case .idle:
            Color.aw.surface.elevated
        }
    }

    // MARK: - Collapsed badge (60px rail) — dot-only, except needs/error glyph; idle = no badge

    /// 13pt filled circle with sidebar-coloured stroke — shared by `.dot` and `.glyph` branches.
    private var collapsedCircle: some View {
        Circle()
            .fill(state.color)
            .overlay {
                Circle()
                    .stroke(Color.aw.surface.sidebar, lineWidth: 1.5)
            }
            .frame(width: 13, height: 13)
    }

    @ViewBuilder
    private var collapsedBadge: some View {
        switch CollapsedStatusBadge.resolve(for: state) {
        case .none:
            EmptyView()
        case .glyph(let glyph):
            ZStack {
                collapsedCircle
                Text(glyph.rawValue)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.aw.status.onLoud)
            }
        case .dot:
            collapsedCircle
        }
    }
}

private struct ClaudeGlyph: View {
    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .frame(width: s * 0.27, height: s * 0.27)

                ForEach(0..<8, id: \.self) { index in
                    Capsule()
                        .frame(width: s * 0.067, height: s * 0.23)
                        .offset(y: -s * 0.33)
                        .rotationEffect(.degrees(Double(index) * 45))
                }
            }
            .frame(width: s, height: s)
        }
    }
}

private struct ShellGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.14, y: rect.minY + rect.height * 0.30))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.14, y: rect.minY + rect.height * 0.70))
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.52, y: rect.minY + rect.height * 0.70))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.88, y: rect.minY + rect.height * 0.70))
        return path
    }
}

// Open brackets `[ ]` splayed around a central gap — "open" + "code", and
// distinct from ShellGlyph's `>_`. Replaced the earlier `‹›` chevrons, which
// read as generic code rather than OpenCode.
private struct OpenCodeGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = rect.minY + rect.height * 0.24
        let bottom = rect.minY + rect.height * 0.76
        let left = rect.minX + rect.width * 0.20
        let right = rect.minX + rect.width * 0.80
        let inset = rect.width * 0.13

        path.move(to: CGPoint(x: left + inset, y: top))
        path.addLine(to: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: left + inset, y: bottom))

        path.move(to: CGPoint(x: right - inset, y: top))
        path.addLine(to: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: right - inset, y: bottom))
        return path
    }
}

// An organic open spiral — Codex iterates inward without closing into the ring
// language used by Grok. Its inner tail flows back toward the right-side
// opening instead of terminating abruptly at the center.
private struct CodexGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        path.move(to: point(0.77, 0.18))
        path.addCurve(to: point(0.15, 0.50), control1: point(0.43, 0.10), control2: point(0.15, 0.25))
        path.addCurve(to: point(0.64, 0.82), control1: point(0.15, 0.76), control2: point(0.39, 0.87))
        path.addCurve(to: point(0.83, 0.63), control1: point(0.76, 0.79), control2: point(0.82, 0.72))
        path.addCurve(to: point(0.54, 0.36), control1: point(0.82, 0.48), control2: point(0.70, 0.36))
        path.addCurve(to: point(0.34, 0.53), control1: point(0.41, 0.36), control2: point(0.34, 0.44))
        path.addCurve(to: point(0.53, 0.68), control1: point(0.34, 0.62), control2: point(0.43, 0.68))
        path.addCurve(to: point(0.69, 0.55), control1: point(0.62, 0.68), control2: point(0.68, 0.62))
        path.addCurve(to: point(0.72, 0.51), control1: point(0.70, 0.52), control2: point(0.71, 0.51))
        return path
    }
}

// Three overlapping rings in a triangle — the mark Codex retired for reading as
// a hazard symbol (ADR 0016), revived here in green as Grok's own identity. Grok
// Build has no cloud story, so the rings carry no false connotation; kept
// distinct from Codex's lavender spiral by both shape and tint. See ADR 0017.
private struct GrokGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // Ring radius and how far each ring's center sits from the glyph center.
        // Offset < radius so the three rings overlap (interlock) rather than
        // merely touch — reads as one knotted mark at 18px.
        let radius = min(rect.width, rect.height) * 0.30
        let offset = radius * 0.72
        for index in 0..<3 {
            let angle = Double(index) * 120 - 90
            let ringCenter = CGPoint(
                x: center.x + offset * CGFloat(cos(angle * .pi / 180)),
                y: center.y + offset * CGFloat(sin(angle * .pi / 180))
            )
            path.addEllipse(in: CGRect(
                x: ringCenter.x - radius, y: ringCenter.y - radius,
                width: radius * 2, height: radius * 2
            ))
        }
        return path
    }
}

public extension AwAgentIcon {
    func localizedAccessibilityName(
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        switch self {
        case .claude:
            "Claude"
        case .codex:
            "Codex"
        case .openCode:
            "OpenCode"
        case .pi:
            "Pi"
        case .grok:
            "Grok"
        case .shell:
            String(
                localized: "Shell",
                bundle: bundle,
                locale: locale,
                comment: "Generic agent name for a plain shell in an accessibility label."
            )
        }
    }
}
