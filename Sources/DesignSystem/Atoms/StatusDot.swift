import AppKit
import SwiftUI

public struct StatusDot: View {
    private let state: AwState
    private let foregroundOverride: Color?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    public init(_ state: AwState) {
        self.state = state
        self.foregroundOverride = nil
    }

    fileprivate init(_ state: AwState, foreground: Color?) {
        self.state = state
        self.foregroundOverride = foreground
    }

    public var body: some View {
        switch state {
        case .thinking:
            ThinkingSpinner(color: foregroundColor)
                // Decorative, mirroring `.waiting`: state comes from the
                // labeled container, and the bridged NSView must not surface
                // its own unlabeled VoiceOver stop.
                .accessibilityHidden(true)

        case .error:
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(foregroundColor)

        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(foregroundColor)

        case .needs:
            // Distinct concentric-ring shape: stays distinguishable from the
            // .idle / .output dots under reduce-motion + color-blindness
            // (where the pulse animation and the needs hue both go away).
            ZStack {
                Circle()
                    .fill(foregroundColor)
                    .frame(width: 9, height: 9)
                Circle()
                    .stroke(foregroundColor, lineWidth: 1.5)
                    .frame(width: 13, height: 13)
            }
            .frame(width: 14, height: 14)
            .shadow(
                color: state.color.opacity(reduceMotion ? 0.45 : (isPulsing ? 0.65 : 0.25)),
                radius: reduceMotion ? 4 : (isPulsing ? 7 : 2)
            )
            .onChange(of: reduceMotion, initial: true) { _, _ in
                guard !reduceMotion else {
                    isPulsing = false
                    return
                }
                withAnimation(AwAnimation.pulseNeeds) { isPulsing = true }
            }

        case .waiting:
            // Pause bars — quiet "waiting for your next turn" (INT-599;
            // replaced the block-cursor bar that read as a blinking
            // cursor/eye). Two bars stay distinct from `.running`'s play
            // triangle even when the tritanopia-adjacent blue/sapphire hues
            // collapse. See AwColor. Outer 10×10 frame preserves the old
            // bar's footprint so pill/footer layouts don't shift.
            Image(systemName: "pause.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(foregroundColor)
                .frame(width: 10, height: 10)
                // The SF Symbol's implicit "Pause" label would leak into a
                // combining container (e.g. AwPill) and misread the state as
                // suspended. The shape is decorative; state comes from the
                // labeled container (INT-599 review).
                .accessibilityHidden(true)

        default:
            // `.idle`'s stroke doesn't clear the WCAG 1.4.11 floor in Latte
            // (see `AwColors.Status.idle`) — deliberate, and no production
            // call site currently passes `.idle` here
            // (`SidebarStatusFooter`/`SidebarGroupView`'s collapsed group dot
            // both draw from closed, hardcoded state sets that exclude it).
            // See INT-361.
            Circle()
                .fill(state == .idle ? Color.clear : foregroundColor)
                .overlay {
                    Circle()
                        .stroke(foregroundColor, lineWidth: 1)
                }
                .frame(width: 8, height: 8)
        }
    }

    private var foregroundColor: Color {
        foregroundOverride ?? state.color
    }
}

public struct AwPill: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let label: String
    private let state: AwState?
    private let baseSurface: Color

    public init(
        _ label: String,
        state: AwState? = nil,
        baseSurface: Color = Color.aw.surface.elevated
    ) {
        self.label = label
        self.state = state
        self.baseSurface = baseSurface
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let state {
                StatusDot(
                    state,
                    foreground: Self.statusDotForeground(for: state, over: baseSurface)
                )
            }
            Text(label)
                .awFont(AwFont.Mono.pill)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(background, in: RoundedRectangle(cornerRadius: AwRadius.pill))
        .overlay {
            RoundedRectangle(cornerRadius: AwRadius.pill)
                .stroke(border, lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private var foreground: Color {
        // Loud states (needs, error) do NOT use `Color.aw.status.onLoud`
        // here — that token assumes an OPAQUE fill, but this pill's
        // background is a translucent 18%-alpha tint over an arbitrary
        // surface (see `background` below), a different contrast
        // relationship entirely. Quiet states route through the standard
        // `onQuiet` token, which adapts with the theme against the
        // lower-opacity pill tint.
        guard let state else { return Color.aw.text }
        return state.isLoud
            ? Self.loudTintForeground(for: state, over: baseSurface)
            : Color.aw.status.onQuiet
    }

    nonisolated static func loudTintForeground(for state: AwState, over baseSurface: Color) -> Color {
        Color.aw.status.tintForeground(for: state, over: baseSurface)
    }

    nonisolated static func statusDotForeground(for state: AwState, over baseSurface: Color) -> Color? {
        state.isLoud ? loudTintForeground(for: state, over: baseSurface) : nil
    }

    private var background: Color {
        guard let state else { return Color.aw.text.opacity(0.10) }
        if state.isLoud, reduceTransparency {
            return Color.aw.status.tintBackground(for: state, over: baseSurface)
        }
        return state.color.opacity(state.isLoud ? AwColors.Status.tintOpacity : 0.10)
    }

    private var border: Color {
        (state?.color ?? .aw.text).opacity(state == nil ? 0.12 : 0.28)
    }
}

public struct KBD: View {
    private let label: String

    public init(_ label: String) {
        self.label = label
    }

    public var body: some View {
        Text(label)
            .awFont(AwFont.Mono.kbd)
            .fontWeight(.semibold)
            .foregroundStyle(Color.aw.text2)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.aw.surface.elevated, in: RoundedRectangle(cornerRadius: AwRadius.kbd))
            .overlay {
                RoundedRectangle(cornerRadius: AwRadius.kbd)
                    .stroke(Color.aw.border2, lineWidth: 0.5)
            }
    }
}
