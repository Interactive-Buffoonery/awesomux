import DesignSystem
import SwiftUI

extension View {
    func palettePanelStyle(isKeyWindow: Bool) -> some View {
        // Fill the host size so the controller can clamp the palette on smaller displays.
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                ZStack {
                    Color.aw.surface.chrome.opacity(0.97)
                    LinearGradient(
                        colors: [Color.aw.accent.opacity(0.08), Color.clear, Color.aw.teal.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AwRadius.window))
            .overlay {
                RoundedRectangle(cornerRadius: AwRadius.window)
                    .strokeBorder(isKeyWindow ? Color.aw.border2 : Color.aw.border, lineWidth: 0.5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: AwRadius.window)
                    // The bare palette host reads the live accent mailbox at each per-summon rebind.
                    .strokeBorder(Color.aw.accent.opacity(isKeyWindow ? 0.18 : 0.06), lineWidth: 1)
            }
            .background {
                RoundedRectangle(cornerRadius: AwRadius.window)
                    .fill(Color.aw.surface.chrome.opacity(isKeyWindow ? 0.97 : 0.94))
                    .awShadow(.sheet, rendering: .composited)
            }
    }

    func paletteHeaderStyle() -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.aw.surface.chrome2.opacity(0.62))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.aw.border2)
                    .frame(height: 0.5)
            }
    }

    func paletteFooterStyle() -> some View {
        awFont(AwFont.Mono.meta)
            .foregroundStyle(Color.aw.text3)
            .padding(.horizontal, 16)
            .frame(minHeight: 42)
            .background(Color.aw.surface.chrome2.opacity(0.70))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.aw.border2)
                    .frame(height: 0.5)
            }
    }

    func paletteRowStyle(isSelected: Bool) -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? Color.aw.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(Color.aw.accent)
                        .frame(width: 2)
                        .padding(.vertical, 7)
                }
            }
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
    }
}
