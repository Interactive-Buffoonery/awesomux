import DesignSystem
import SwiftUI

enum FloatingPanelChromeMetrics {
    static let closeButtonEdgeInset: CGFloat = 18
    static let focusRingOpacity: Double = 1
    static let focusRingLineWidth: CGFloat = 1.25
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
        .overlay {
            Circle()
                .stroke(
                    isFocused ? Color.aw.red.opacity(FloatingPanelChromeMetrics.focusRingOpacity) : Color.clear,
                    lineWidth: FloatingPanelChromeMetrics.focusRingLineWidth
                )
        }
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .help("Close")
        .accessibilityLabel(accessibilityLabel)
    }
}
