import SwiftUI

public enum AwFocusRing {
    public static let standardLineWidth: CGFloat = 1.25
    public static let increasedContrastLineWidth: CGFloat = 2
    public static let glowRadius: CGFloat = 5

    public static func lineWidth(increasedContrast: Bool) -> CGFloat {
        increasedContrast ? increasedContrastLineWidth : standardLineWidth
    }
}

public extension View {
    func awFocusRing(
        _ isFocused: Bool,
        cornerRadius: CGFloat,
        inset: CGFloat = 1
    ) -> some View {
        modifier(AwFocusRingModifier(
            isFocused: isFocused,
            cornerRadius: cornerRadius,
            inset: inset
        ))
    }
}

// Resolves the accent from \.awAccent: callers need an AppearanceBridge
// ancestor, or the ring renders the default accent (bites inside the
// unbridged NSHostingController panel roots).
private struct AwFocusRingModifier: ViewModifier {
    let isFocused: Bool
    let cornerRadius: CGFloat
    let inset: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.awAccent) private var accentResolver

    private var accentColor: Color { Color.aw.accent(accentResolver.accent) }
    private var accentGlowColor: Color { Color.aw.accentGlow(accentResolver.accent) }

    func body(content: Content) -> some View {
        let isHighContrast = contrast == .increased
        let lineWidth = AwFocusRing.lineWidth(increasedContrast: isHighContrast)

        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .inset(by: inset)
                    .stroke(accentColor, lineWidth: lineWidth)
                    .opacity(isFocused ? 1 : 0)
            }
            .shadow(
                color: accentGlowColor.opacity(isFocused && !isHighContrast ? 0.45 : 0),
                radius: isFocused ? AwFocusRing.glowRadius : 0
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isFocused)
    }
}
