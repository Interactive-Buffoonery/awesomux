import DesignSystem
import SwiftUI

/// Shared chrome for the app’s button-opened menus: rounded panel,
/// chrome fill, accent hairline, and overlay shadow.
struct AppMenuChrome: ViewModifier {
    let accent: Color

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: AwRadius.panel)
                    .fill(Color.aw.surface.chrome)
                    .overlay {
                        RoundedRectangle(cornerRadius: AwRadius.panel)
                            .stroke(accent.opacity(0.38), lineWidth: 0.75)
                    }
                    .awShadow(.overlay)
                    .accessibilityHidden(true)
            }
    }
}

struct AppMenuRowButtonStyle: ButtonStyle {
    let tone: Color
    let filled: Bool
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let active = isHovering || configuration.isPressed
        let fillOpacity = filled ? (active ? 0.18 : 0.12) : (active ? 0.10 : 0.05)
        return configuration.label
            .background(tone.opacity(fillOpacity), in: RoundedRectangle(cornerRadius: AwRadius.pill))
            .overlay {
                RoundedRectangle(cornerRadius: AwRadius.pill)
                    .stroke(tone.opacity(filled ? 0.38 : (active ? 0.28 : 0.16)), lineWidth: 0.5)
            }
            .onHover { isHovering = $0 }
    }
}
