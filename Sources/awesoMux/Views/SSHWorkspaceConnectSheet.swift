import AwesoMuxConfig
import AwesoMuxCore
import SwiftUI

struct SSHWorkspaceConnectSheet: View {
    let groupName: String
    let onCancel: () -> Void
    let onConnect: (RemoteTarget) -> Void

    @Environment(AppSettingsStore.self) private var appSettingsStore
    @State private var destination = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        let target = SSHWorkspaceDestinationValidation.target(from: destination)
        let validationMessage = SSHWorkspaceDestinationValidation.message(for: destination)
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect via SSH")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Destination")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("my-server", text: $destination)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .focused($isFocused)
                .accessibilityLabel("SSH destination")
                .onSubmit { connect(target) }
            if let message = validationMessage ?? settingsErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Creates a managed SSH workspace in “\(groupName).”\nOpenSSH will use your existing config and credentials.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !backgroundSessionsEnabled {
                Label(
                    "Managed SSH requires background terminal sessions. awesoMux will turn them on when you connect.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(primaryButtonLabel) {
                    connect(target)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(target == nil)
                .accessibilityHint(
                    validationMessage
                        ?? String(
                            localized: "Enter a destination to enable Connect",
                            comment: "Accessibility hint for the disabled Connect button in the Connect via SSH sheet"
                        ),
                    isEnabled: target == nil
                )
            }
        }
        .padding(20)
        .frame(minWidth: 360, idealWidth: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connect via SSH")
        .onAppear { isFocused = true }
    }

    private func connect(_ target: RemoteTarget?) {
        guard let target else { return }
        guard backgroundSessionsEnabled || enableBackgroundSessions() else { return }
        onConnect(target)
    }

    private var backgroundSessionsEnabled: Bool {
        appSettingsStore.terminal.value.commandBridgeEnabled
    }

    private var primaryButtonLabel: LocalizedStringKey {
        backgroundSessionsEnabled ? "Connect" : "Enable and Connect"
    }

    private var settingsErrorMessage: String? {
        backgroundSessionsEnabled ? nil : appSettingsStore.latestError?.displayText
    }

    private func enableBackgroundSessions() -> Bool {
        appSettingsStore.terminal.update { $0.commandBridgeEnabled = true }
        return backgroundSessionsEnabled
    }
}
