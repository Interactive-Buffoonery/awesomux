import AwesoMuxConfig
import DesignSystem
import SwiftUI

/// Three theme cards rendered as a radio group: Mocha, Latte, System.
/// Each card shows a miniature window mock so the user can compare the
/// chrome surface tones at a glance. Bound to `AppearanceConfig.Theme`
/// directly because the design system layer has no awareness of the
/// config enum and this view is app-side.
struct SettingsThemePreview: View {
    enum Variant {
        case full
        case compact
        case grid
    }

    @Binding var selection: AppearanceConfig.Theme
    var variant: Variant = .full
    @Environment(\.awAccent) private var accentResolver
    @Environment(\.colorSchemeContrast) private var contrast

    private var metrics: Metrics {
        switch variant {
        case .full:
            Metrics(
                cardWidth: 140,
                previewHeight: 64,
                cardPadding: 10,
                cardSpacing: 14,
                sidebarWidth: 22
            )
        case .compact:
            Metrics(
                cardWidth: 94,
                previewHeight: 44,
                cardPadding: 8,
                cardSpacing: 8,
                sidebarWidth: 16
            )
        case .grid:
            // Sized to the handoff's 90pt card so three fit the
            // label-left grid row at the 880pt settings width
            // (settings.jsx:165). Otherwise visually matches .compact.
            Metrics(
                cardWidth: 90,
                previewHeight: 44,
                cardPadding: 8,
                cardSpacing: 8,
                sidebarWidth: 16
            )
        }
    }

    var body: some View {
        HStack(spacing: metrics.cardSpacing) {
            ForEach(AppearanceConfig.Theme.cardDisplayOrder, id: \.self) { theme in
                card(for: theme)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Theme")
    }

    @ViewBuilder
    private func card(for theme: AppearanceConfig.Theme) -> some View {
        let isSelected = selection == theme
        let accentColor = Color.aw.accent(accentResolver.accent)
        Button {
            selection = theme
        } label: {
            VStack(alignment: .leading, spacing: variant != .full ? 6 : 8) {
                preview(for: theme)
                    .frame(height: metrics.previewHeight)
                    .clipShape(RoundedRectangle(cornerRadius: AwRadius.panel - 2))

                Text(theme.displayName)
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(isSelected ? Color.aw.text : Color.aw.text2)
            }
            .padding(metrics.cardPadding)
            .frame(width: metrics.cardWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AwRadius.panel)
                    .fill(Color.aw.surface.elevated)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AwRadius.panel)
                    .stroke(
                        isSelected ? accentColor : Color.aw.border,
                        lineWidth: selectedStrokeWidth(isSelected: isSelected)
                    )
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    // Second channel for the selection state — under
                    // reduced color perception or high glare a thin
                    // accent border can collapse. The checkmark glyph
                    // gives an unambiguous "this one is on" signal.
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func selectedStrokeWidth(isSelected: Bool) -> CGFloat {
        // Mirror SidebarSessionTile.tileBorder: thicker stroke under
        // Increase Contrast so the selection ring stays perceptible.
        guard isSelected else { return 0.5 }
        return contrast == .increased ? 2.5 : 1.5
    }

    @ViewBuilder
    private func preview(for theme: AppearanceConfig.Theme) -> some View {
        let palette = ThemePreviewPalette.palette(for: theme)
        HStack(spacing: 0) {
            // Sidebar swatch
            Rectangle()
                .fill(palette.sidebar)
                .frame(width: metrics.sidebarWidth)
                .overlay(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(palette.text.opacity(0.55))
                                .frame(width: variant != .full ? 10 : 14, height: 3)
                        }
                    }
                    .padding(variant != .full ? 4 : 6)
                }

            // Content swatch
            Rectangle()
                .fill(palette.surface)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.aw.accent(accentResolver.accent))
                            .frame(width: variant != .full ? 16 : 20, height: 3)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(palette.text.opacity(0.4))
                            .frame(width: variant != .full ? 26 : 36, height: 3)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(palette.text.opacity(0.4))
                            .frame(width: variant != .full ? 20 : 28, height: 3)
                    }
                    .padding(variant != .full ? 6 : 8)
                }
        }
    }

    private struct Metrics {
        let cardWidth: CGFloat
        let previewHeight: CGFloat
        let cardPadding: CGFloat
        let cardSpacing: CGFloat
        let sidebarWidth: CGFloat
    }
}

/// Static color samples for the theme cards. Resolved at build time so
/// the cards always show *all three* theme tones regardless of which
/// theme is currently active. Going through `Color.aw.dynamic(...)`
/// would instead always render the user's *current* theme three times.
private enum ThemePreviewPalette {
    struct Sample {
        let sidebar: Color
        let surface: Color
        let text: Color
    }

    // Static palette samples — building these once instead of
    // reconstructing on every theme card render avoids three Color
    // allocations per body evaluation in the ForEach.
    static let darkSample = Sample(
        sidebar: Color(.sRGB, red: 0.094, green: 0.094, blue: 0.145, opacity: 1),
        surface: Color(.sRGB, red: 0.117, green: 0.117, blue: 0.180, opacity: 1),
        text: Color(.sRGB, red: 0.804, green: 0.839, blue: 0.957, opacity: 1)
    )
    static let lightSample = Sample(
        sidebar: Color(.sRGB, red: 0.902, green: 0.914, blue: 0.937, opacity: 1),
        surface: Color(.sRGB, red: 0.937, green: 0.945, blue: 0.961, opacity: 1),
        text: Color(.sRGB, red: 0.298, green: 0.310, blue: 0.412, opacity: 1)
    )
    static let systemSample = Sample(
        // For the "System" card, show a split preview: mocha sidebar
        // beside a latte surface. Visually communicates "follows OS".
        sidebar: Color(.sRGB, red: 0.094, green: 0.094, blue: 0.145, opacity: 1),
        surface: Color(.sRGB, red: 0.937, green: 0.945, blue: 0.961, opacity: 1),
        text: Color(.sRGB, red: 0.804, green: 0.839, blue: 0.957, opacity: 1)
    )

    static func palette(for theme: AppearanceConfig.Theme) -> Sample {
        switch theme {
        case .dark: return darkSample
        case .light: return lightSample
        case .system: return systemSample
        }
    }
}

extension AppearanceConfig.Theme {
    /// Card order for the Settings theme picker: Mocha (dark — the product's
    /// default identity) first, then Latte, then System. Deliberately not the
    /// `allCases` declaration order, which other consumers rely on.
    static let cardDisplayOrder: [AppearanceConfig.Theme] = [.dark, .light, .system]

    var displayName: String {
        switch self {
        case .system: "System"
        case .dark: "Mocha"
        case .light: "Latte"
        }
    }
}
