import SwiftUI

/// Compact chrome buttons for awesoMux panels. Apply with
/// `.awButtonStyle(_:)` so the stock focus effect gives way to the
/// accent focus ring.
public struct AwButtonStyle: ButtonStyle {
    public enum Kind: Sendable {
        case primary
        case ghost
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
    @Environment(\.self) private var environment
    @State private var isHovered = false

    private var accent: AwAccent { accentResolver.accent }

    var body: some View {
        styledLabel
            .contentShape(RoundedRectangle(cornerRadius: AwRadius.button))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .awFocusRing(isFocused, cornerRadius: AwRadius.button, inset: -2)
            .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var styledLabel: some View {
        switch kind {
        case .primary:
            let fill = Color.aw.accent(accent)
            configuration.label
                .awFont(AwFont.UI.meta)
                .fontWeight(.semibold)
                .foregroundStyle(onAccent(fill))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(fill, in: RoundedRectangle(cornerRadius: AwRadius.button))
                .overlay {
                    RoundedRectangle(cornerRadius: AwRadius.button)
                        .fill(Color.white.opacity(isHovered && isEnabled ? 0.12 : 0))
                }
                .awGlow(color: Color.aw.accentSoft(accent), radius: 6)
        case .ghost:
            configuration.label
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text2)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(
                    isHovered && isEnabled ? Color.aw.surface.hover : Color.clear,
                    in: RoundedRectangle(cornerRadius: AwRadius.button)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: AwRadius.button)
                        .stroke(Color.aw.border2, lineWidth: 0.5)
                }
        case .link:
            configuration.label
                .awFont(AwFont.UI.meta)
                .fontWeight(.medium)
                .foregroundStyle(Color.aw.accentOnChrome(accent))
                .underline(isHovered && isEnabled)
                .padding(.horizontal, 4)
                .frame(height: 26)
        }
    }

    // Dark accents (several Latte fills) need a light label to keep 4.5:1.
    private func onAccent(_ fill: Color) -> Color {
        let resolved = fill.resolve(in: environment)
        let luminance = 0.2126 * resolved.linearRed + 0.7152 * resolved.linearGreen + 0.0722 * resolved.linearBlue
        return luminance < 0.18 ? Color.white : Color(nsColor: NSColor.awHex("#11111b"))
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
