import AwesoMuxConfig
import DesignSystem
import SwiftUI

struct QuickSettingsSheet: View {
    @Environment(AppSettingsStore.self) private var appSettingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Quick settings")
                .awFont(AwFont.UI.title)
                .foregroundStyle(Color.aw.text)
                .padding(.bottom, 14)

            QuickSettingsRow(label: "Theme", isFirst: true) {
                SettingsThemePreview(
                    selection: appSettingsStore.appearance.binding(\.theme),
                    variant: .compact
                )
            }

            QuickSettingsRow(label: "Notifications") {
                Toggle(
                    "Mute notifications",
                    isOn: appSettingsStore.notifications.binding(\.muted)
                )
                .toggleStyle(.switch)
            }

            Button("More settings…") {
                openWindow(id: AwesoMuxSceneID.settings)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 16)
        }
        .padding(18)
        .frame(width: AwSettings.quickSheetWidth, alignment: .leading)
        .background(Color.aw.surface.window)
    }
}

private struct QuickSettingsRow<Control: View>: View {
    let label: String
    var isFirst = false
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !isFirst {
                Rectangle()
                    .fill(Color.aw.border)
                    .frame(height: 0.5)
                    .padding(.bottom, 2)
            }

            Text(label)
                .awFont(AwFont.UI.label)
                .foregroundStyle(Color.aw.text)
                .accessibilityHidden(true)

            control()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }
}
