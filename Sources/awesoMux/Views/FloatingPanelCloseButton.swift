import DesignSystem
import SwiftUI

extension View {
    /// Focus treatment for the panel-family chrome controls (close, minimize,
    /// promote).
    ///
    /// `.focusable()` is the load-bearing call. `.focused(_:)` only *binds* a
    /// focus state — it does not put a plain `Button` into the focus chain — so
    /// every one of these controls declared a ring that could never render
    /// (#372). Same distinction `SidebarSessionTile` documents.
    ///
    /// The ring appears only while macOS "Keyboard navigation" is on. That is
    /// the system's focus model, not a bug: do not "fix" its absence by
    /// drawing the ring unconditionally.
    func awPanelFocusRing(
        _ shape: some InsettableShape,
        color: Color,
        isFocused: FocusState<Bool>.Binding,
        inset: CGFloat = 0
    ) -> some View {
        modifier(PanelFocusRingModifier(shape: shape, color: color, focus: isFocused, inset: inset))
    }
}

private struct PanelFocusRingModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let color: Color
    let focus: FocusState<Bool>.Binding
    let inset: CGFloat

    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused(focus)
            // AppKit's own ring would double up with the stroke below, and it
            // draws outside the frame where this chrome has no room for it.
            .focusEffectDisabled()
            .overlay {
                shape
                    .inset(by: inset)
                    .stroke(
                        focus.wrappedValue ? color : Color.clear,
                        // Inherits the design system's 2pt increased-contrast
                        // policy rather than pinning a local width.
                        lineWidth: AwFocusRing.lineWidth(increasedContrast: contrast == .increased)
                    )
            }
    }
}

struct FloatingPanelCloseButton: View {
    let accessibilityLabel: String
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private var isHighlighted: Bool {
        isHovered || isFocused
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHighlighted ? Color.aw.red : Color.aw.text3)
        .background(
            Circle()
                .fill(isHighlighted ? Color.aw.red.opacity(0.14) : Color.clear)
        )
        .awPanelFocusRing(Circle(), color: Color.aw.red, isFocused: $isFocused)
        .onHover { isHovered = $0 }
        .help("Close")
        .accessibilityLabel(accessibilityLabel)
    }
}
