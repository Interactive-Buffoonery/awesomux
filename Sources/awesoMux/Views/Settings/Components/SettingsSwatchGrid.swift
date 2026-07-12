import DesignSystem
import SwiftUI

/// Color-circle picker for accent selection. Renders one swatch per
/// `AwAccent` case; the selected swatch is ringed in the standard text
/// color. The component is purely visual — it does not read or write
/// configuration; callers bind to whatever store/state they need.
struct SettingsSwatchGrid: View {
    @Binding var selection: AwAccent
    @Environment(\.colorSchemeContrast) private var contrast

    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 30, maximum: 36), spacing: 12, alignment: .leading)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(AwAccent.allCases, id: \.self) { accent in
                swatchButton(accent)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Accent color")
    }

    @ViewBuilder
    private func swatchButton(_ accent: AwAccent) -> some View {
        let isSelected = accent == selection
        // Two-channel selection signal: a ring stroke (existing) plus a
        // checkmark glyph inside the selected swatch. Color-blind users
        // and users with reduced contrast sensitivity get a second
        // affordance beyond the thin outer ring. Stroke thickens under
        // `colorSchemeContrast == .increased` to match the pattern used
        // by SidebarSessionTile.tileBorder.
        Button {
            selection = accent
        } label: {
            ZStack {
                Circle()
                    .fill(Color.aw.accent(accent))
                    .frame(width: 22, height: 22)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.aw.surface.window)
                        .accessibilityHidden(true)
                    Circle()
                        .stroke(Color.aw.text, lineWidth: contrast == .increased ? 2.5 : 1.5)
                        .frame(width: 28, height: 28)
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(accent.displayName)
        .accessibilityLabel(accent.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
