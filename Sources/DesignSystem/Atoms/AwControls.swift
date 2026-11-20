import SwiftUI

/// Mono chrome buttons for awesoMux panels, cut from the sidebar's Update
/// Available button. Apply with `.awButtonStyle(_:)` so the stock focus
/// effect gives way to the accent focus ring.
public struct AwButtonStyle: ButtonStyle {
    public enum Kind: Sendable {
        /// Accent-soft fill, primary text: the Update Available look.
        case primary
        /// Hairline outline, secondary text.
        case ghost
        /// Bare accent text.
        case link
    }

    let kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }

    public func makeBody(configuration: Configuration) -> some View {
        AwButtonBody(kind: kind, configuration: configuration)
    }
}

private struct AwButtonBody: View {
    let kind: AwButtonStyle.Kind
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.awAccent) private var accentResolver
    @State private var isHovered = false

    private var accent: AwAccent { accentResolver.accent }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: AwRadius.pill) }
    private var isActive: Bool { isEnabled && (isHovered || configuration.isPressed) }

    var body: some View {
        styledLabel
            .awFont(AwFont.Mono.meta)
            .lineLimit(1)
            .frame(minHeight: 28)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.4)
            .awFocusRing(isFocused, cornerRadius: AwRadius.pill, inset: -2)
            .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var styledLabel: some View {
        switch kind {
        case .primary:
            configuration.label
                .fontWeight(.medium)
                .foregroundStyle(Color.aw.text)
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
                .background {
                    ZStack {
                        shape.fill(Color.aw.accentSoft(accent))
                        shape.fill(Color.aw.accent(accent).opacity(configuration.isPressed ? 0.3 : isActive ? 0.15 : 0))
                    }
                }
        case .ghost:
            configuration.label
                .foregroundStyle(isActive ? Color.aw.text : Color.aw.text2)
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
                .background(isActive ? Color.aw.surface.hover : Color.clear, in: shape)
                .overlay { shape.stroke(Color.aw.border2, lineWidth: 0.5) }
        case .link:
            configuration.label
                .fontWeight(.medium)
                .foregroundStyle(Color.aw.accentOnChrome(accent))
                .underline(isActive)
                .padding(.horizontal, 4)
        }
    }
}

/// A flat 24x13 switch: accent track when on, `surface.track` when off,
/// window-colour knob, no shadow. VoiceOver reads it as a standard switch.
public struct AwToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        AwToggleBody(configuration: configuration)
    }
}

private struct AwToggleBody: View {
    let configuration: ToggleStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool
    @Environment(\.awAccent) private var accentResolver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                configuration.label
                track
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($isFocused)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityRepresentation {
            // Not rendered; only gives VoiceOver the native switch role.
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }

    private var track: some View {
        Capsule()
            .fill(configuration.isOn ? Color.aw.accent(accentResolver.accent) : Color.aw.surface.track)
            .frame(width: 24, height: 13)
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.aw.surface.window)
                    .frame(width: 9, height: 9)
                    .padding(2)
            }
            .awFocusRing(isFocused, cornerRadius: 7, inset: -2)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isOn)
    }
}

public extension View {
    func awButtonStyle(_ kind: AwButtonStyle.Kind) -> some View {
        buttonStyle(AwButtonStyle(kind)).focusEffectDisabled()
    }
}
