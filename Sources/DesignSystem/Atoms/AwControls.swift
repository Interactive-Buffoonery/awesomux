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
                        // Kept light: any stronger accent wash drops `text` under
                        // 4.5:1 (Mocha green, Latte mauve are the tightest).
                        shape.fill(Color.aw.accent(accent).opacity(configuration.isPressed ? 0.10 : isActive ? 0.05 : 0))
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

/// A flat 24x13 switch: accent track when on, outlined `surface.track` when
/// off, window-colour knob, no shadow. VoiceOver reads it as a standard switch.
public struct AwToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        AwToggleBody(configuration: configuration)
    }
}

/// `.plain` dims a disabled button's whole label on macOS; the toggle dims
/// only its track, so a disabled row's text stays readable.
private struct UndimmedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
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
        .buttonStyle(UndimmedButtonStyle())
        .focusEffectDisabled()
        .focused($isFocused)
        .accessibilityRepresentation {
            // Not rendered; only gives VoiceOver the native switch role.
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }

    private var track: some View {
        Capsule()
            .fill(configuration.isOn ? Color.aw.accent(accentResolver.accent) : Color.aw.surface.track)
            // The off track alone is under 3:1 against the window (WCAG 1.4.11).
            .overlay {
                if !configuration.isOn {
                    Capsule().strokeBorder(Color.aw.text2, lineWidth: 1)
                }
            }
            .frame(width: 24, height: 13)
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.aw.surface.window)
                    .frame(width: 9, height: 9)
                    .padding(2)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .awFocusRing(isFocused, cornerRadius: 7, inset: -2)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isOn)
    }
}

public extension View {
    func awButtonStyle(_ kind: AwButtonStyle.Kind) -> some View {
        buttonStyle(AwButtonStyle(kind)).focusEffectDisabled()
    }
}
