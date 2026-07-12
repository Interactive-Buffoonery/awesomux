import AppKit
import AwesoMuxConfig
import DesignSystem
import SwiftUI

struct GeneralSettingsPane: View {
    private static let openAtLoginLabel = String(
        localized: "Open at Login",
        comment: "Settings field and VoiceOver label for controlling whether awesoMux opens when the user logs in."
    )

    @Environment(AppSettingsStore.self) private var appSettingsStore
    @State private var loginItemModel = LoginItemSettingsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(index: 1, title: "Startup", subtitle: "What awesoMux does the moment you launch it.") {
                SettingsField(
                    label: "Restore workspaces",
                    hint: "Reopen the sidebar groups and sessions from the previous launch. Applies on next launch.",
                    isFirst: true,
                    forwardsAccessibilityToControl: true
                ) {
                    Toggle("Restore workspaces", isOn: appSettingsStore.general.binding(\.restoreWorkspaces))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsField(
                    label: Self.openAtLoginLabel,
                    hint: loginItemModel.statusHint,
                    forwardsAccessibilityToControl: true,
                    forwardsHintToControl: false
                ) {
                    VStack(alignment: .trailing, spacing: 4) {
Toggle(
    isOn: Binding(
        get: { loginItemModel.isRequested },
        set: { loginItemModel.setRequested($0) }
    )
) {
    Text(Self.openAtLoginLabel)
}
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(loginItemModel.status == .unknown || loginItemModel.status == .unavailable)
                        .accessibilityLabel(Text(Self.openAtLoginLabel))
                        .accessibilityValue(Text(loginItemModel.accessibilityValue))
                        .accessibilityHint(Text(loginItemModel.statusHint))

                        Text(loginItemModel.statusLabel)
                            .awFont(AwFont.UI.meta)
                            .foregroundStyle(Color.aw.text2)
                            .accessibilityHidden(true)

                        if let errorMessage = loginItemModel.errorMessage {
                            Text(errorMessage)
                                .awFont(AwFont.UI.meta)
                                .foregroundStyle(Color.aw.status.needs)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }

            SettingsSection(index: 2, title: "Sidebar") {
                SettingsField(
                    label: "Compact mode",
                    hint: "Tighter row spacing for users with many sessions in a single workspace.",
                    isFirst: true,
                    forwardsAccessibilityToControl: true
                ) {
                    Toggle("Sidebar compact mode", isOn: appSettingsStore.general.binding(\.sidebarCompactMode))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            SettingsSection(
                index: 3,
                title: "Menu bar",
                subtitle: "Show a tiny attention dot in the macOS menu bar when a workspace needs input."
            ) {
                SettingsField(
                    label: "Show in menu bar",
                    hint: "The dot only appears while a workspace needs input; idle workspaces keep the menu bar clear.",
                    isFirst: true,
                    forwardsAccessibilityToControl: true
                ) {
                    Toggle("Show in menu bar", isOn: appSettingsStore.general.binding(\.showMenuBarMiniStatus))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
        }
        .onAppear {
            loginItemModel.refresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            loginItemModel.refresh()
        }
    }
}
