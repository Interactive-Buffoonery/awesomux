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
                    // The hint is forwarded as the toggle's VoiceOver hint, so
                    // "Applies on next launch" was actively wrong for screen
                    // reader users: turning this on now validates the saved
                    // file immediately, and can pause saving as a result.
                    hint:
                        "Reopen the sidebar groups and sessions from the previous launch. Restoring happens at the next launch; turning this on checks the saved file right away.",
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
                        .disabled(loginItemModel.status == .unknown)
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

            SettingsSection(
                index: 2,
                title: String(localized: "Menu bar", comment: "General settings section title"),
                subtitle: String(
                    localized: "Choose when the awesoMux smile appears in the macOS menu bar.",
                    comment: "General settings menu bar section description"
                )
            ) {
                SettingsField(
                    label: String(localized: "Visibility", comment: "Menu bar visibility settings label"),
                    hint: String(
                        localized: "The badge uses your accent color when a workspace needs acknowledgement or has an unanswered turn.",
                        comment: "Menu bar attention badge settings hint"
                    ),
                    isFirst: true
                ) {
                    SettingsSegmented(
                        options: menuBarVisibilityOptions,
                        selection: appSettingsStore.general.binding(\.menuBarVisibility)
                    )
                    .accessibilityLabel(
                        String(
                            localized: "Menu bar visibility",
                            comment: "Accessibility label for menu bar visibility choices"
                        )
                    )
                    .accessibilityHint(
                        String(
                            localized:
                                "Controls when the awesoMux smile appears. The accent-colored badge marks workspaces that need acknowledgement or have an unanswered turn.",
                            comment: "Accessibility hint for menu bar visibility choices"
                        ))
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

    private var menuBarVisibilityOptions: [SettingsSegmented<GeneralConfig.MenuBarVisibility>.Option] {
        [
            .init(value: .never, label: String(localized: "Never", comment: "Menu bar visibility choice")),
            .init(value: .needsInput, label: String(localized: "Needs input", comment: "Menu bar visibility choice")),
            .init(value: .always, label: String(localized: "Always", comment: "Menu bar visibility choice")),
        ]
    }
}
