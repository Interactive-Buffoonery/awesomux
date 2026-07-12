import DesignSystem
import SwiftUI

/// Row in the Settings sidebar. Renders with no list chrome, active-state
/// accent rail, hover background, and accent glow that scales with the
/// user-configured glow strength via the standard `awGlow` modifier.
struct SettingsSidebarItem<Section: Hashable>: View {
    let section: Section
    let title: String
    let systemImage: String
    @Binding var selection: Section
    @Environment(\.awAccent) private var accentResolver

    @State private var isHovered = false

    private var isActive: Bool { selection == section }

    private var accentColor: Color { Color.aw.accent(accentResolver.accent) }
    private var accentGlowColor: Color { Color.aw.accentGlow(accentResolver.accent) }

    var body: some View {
        Button {
            selection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .regular))
                    .frame(width: 16)
                    .foregroundStyle(isActive ? accentColor : Color.aw.text3)
                    .accessibilityHidden(true)

                Text(title)
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(isActive ? Color.aw.text : Color.aw.text2)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .overlay(alignment: .leading) { activeRail }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    @ViewBuilder
    private var background: some View {
        if isActive {
            RoundedRectangle(cornerRadius: AwRadius.button)
                .fill(Color.aw.surface.active)
        } else if isHovered {
            RoundedRectangle(cornerRadius: AwRadius.button)
                .fill(Color.aw.surface.hover)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var activeRail: some View {
        if isActive {
            RoundedRectangle(cornerRadius: 1)
                .fill(accentColor)
                .frame(width: 2)
                .padding(.vertical, 6)
                .offset(x: -1)
                .awGlow(color: accentGlowColor, radius: 8)
        }
    }
}
