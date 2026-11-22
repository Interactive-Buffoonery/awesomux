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
            // Rows and footers give way around buttons; labels never truncate.
            .fixedSize()
            .frame(minHeight: 28)
            .contentShape(shape)
            // Ghost stays legible disabled: Back on the first step keeps its place.
            .opacity(isEnabled ? 1 : kind == .ghost ? 0.55 : 0.4)
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
                        // Kept light: any stronger accent wash drops `text` under
                        // 4.5:1 (Mocha green, Latte mauve are the tightest).
                        shape.fill(Color.aw.accent(accent).opacity(configuration.isPressed ? 0.10 : isActive ? 0.05 : 0))
                    }
                }
                // Hover and press read from the border, so the fill can stay light.
                .overlay {
                    if isActive {
                        shape.strokeBorder(Color.aw.accent(accent).opacity(0.5), lineWidth: 1)
                    }
                }
        case .ghost:
            configuration.label
                .foregroundStyle(isActive ? Color.aw.text : Color.aw.railText)
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

/// A flat 24x13 switch, no shadow. On: accent-on-chrome track, window-colour
/// knob. Off: outlined track, smaller `text2` knob. Track edge and knob clear
/// 3:1 in every palette and accent (WCAG 1.4.11). VoiceOver reads it as a
/// standard switch.
public struct AwToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        AwToggleBody(configuration: configuration)
    }
}

/// Draws the track here for its pressed state. Also replaces `.plain`, which
/// dims a disabled button's whole label on macOS; only the track dims, so a
/// disabled row's text stays readable.
private struct AwSwitchButtonStyle: ButtonStyle {
    let isOn: Bool
    let isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
            AwSwitchTrack(isOn: isOn, isPressed: configuration.isPressed, isFocused: isFocused)
        }
        .contentShape(Rectangle())
    }
}

private struct AwToggleBody: View {
    let configuration: ToggleStyleConfiguration

    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
        }
        .buttonStyle(AwSwitchButtonStyle(isOn: configuration.isOn, isFocused: isFocused))
        .focusEffectDisabled()
        .focused($isFocused)
        .accessibilityRepresentation {
            // Not rendered; only gives VoiceOver the native switch role.
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

private struct AwSwitchTrack: View {
    let isOn: Bool
    let isPressed: Bool
    let isFocused: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.awAccent) private var accentResolver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Capsule()
            .fill(isOn ? Color.aw.accentOnChrome(accentResolver.accent) : Color.aw.surface.window)
            .overlay {
                if !isOn {
                    Capsule().strokeBorder(Color.aw.text2, lineWidth: 1)
                }
            }
            .frame(width: 24, height: 13)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? Color.aw.surface.window : Color.aw.text2)
                    .frame(width: isOn ? 9 : 7, height: isOn ? 9 : 7)
                    .padding(isOn ? 2 : 3)
            }
            .brightness(isPressed ? -0.06 : 0)
            .opacity(isEnabled ? 1 : 0.45)
            .awFocusRing(isFocused, cornerRadius: 7, inset: -2)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isOn)
    }
}

public extension View {
    func awButtonStyle(_ kind: AwButtonStyle.Kind) -> some View {
        buttonStyle(AwButtonStyle(kind)).focusEffectDisabled()
    }
}
