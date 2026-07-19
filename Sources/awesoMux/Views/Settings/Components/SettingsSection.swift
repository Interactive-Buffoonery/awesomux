import DesignSystem
import SwiftUI

/// Section block in a Settings pane. Numbered kicker (`01`), large title,
/// optional subtitle, then a content slot for `SettingsField` rows.
struct SettingsSection<Content: View>: View {
    let index: Int
    let title: String
    var subtitle: String?
    var accessibilityFocus: AccessibilityFocusState<Bool>.Binding?
    @ViewBuilder let content: Content

    init(
        index: Int,
        title: String,
        subtitle: String? = nil,
        accessibilityFocus: AccessibilityFocusState<Bool>.Binding? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.index = index
        self.title = title
        self.subtitle = subtitle
        self.accessibilityFocus = accessibilityFocus
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kickerText)
                .awFont(AwFont.Mono.kicker)
                .tracking(1)
                .textCase(.uppercase)
                .foregroundStyle(Color.aw.text3)
                .padding(.bottom, 6)
                .accessibilityHidden(true)

            titleView

            if let subtitle {
                Text(subtitle)
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text2)
                    .padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                content
            }
            .padding(.top, 18)
        }
        .padding(.bottom, AwSpacing.sectionGap)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var titleView: some View {
        if let accessibilityFocus {
            titleLabel
                .accessibilityFocused(accessibilityFocus)
        } else {
            titleLabel
        }
    }

    private var titleLabel: some View {
        Text(title)
            .awFont(AwFont.UI.title)
            .foregroundStyle(Color.aw.text)
            .accessibilityAddTraits(.isHeader)
    }

    private var kickerText: String {
        // Clamp to 0...99 so `%02d` always renders as a two-character
        // kicker. The handoff uses sequential 01..08 numbering today, but
        // the clamp makes the component safe to reuse without surprise.
        let clamped = min(max(index, 0), 99)
        return String(format: "%02d", clamped)
    }
}
