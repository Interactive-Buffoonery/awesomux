import AwesoMuxConfig
import AwesoMuxCore
import SwiftUI

struct SSHWorkspaceConnectSheet: View {
    let groupName: String
    let initialDestination: String?
    let onCancel: () -> Void
    let onConnect: (RemoteTarget) -> Void

    @Environment(AppSettingsStore.self) private var appSettingsStore
    @State private var destination: String
    @FocusState private var isFocused: Bool

    init(
        groupName: String,
        initialDestination: String? = nil,
        onCancel: @escaping () -> Void,
        onConnect: @escaping (RemoteTarget) -> Void
    ) {
        self.groupName = groupName
        self.initialDestination = initialDestination
        self.onCancel = onCancel
        self.onConnect = onConnect
        _destination = State(initialValue: initialDestination ?? "")
    }

    var body: some View {
        let target = SSHWorkspaceDestinationValidation.target(from: destination)
        let validationMessage = SSHWorkspaceDestinationValidation.message(for: destination)
        VStack(alignment: .leading, spacing: 16) {
            Text(sheetTitle)
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
            Text(explanation)
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
        .accessibilityLabel(sheetTitle)
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

    private var primaryButtonLabel: String {
        if initialDestination != nil {
            if backgroundSessionsEnabled {
                return String(
                    localized: "Create Managed Workspace",
                    comment: "Button that creates a managed workspace from an ordinary SSH connection"
                )
            }
            return String(
                localized: "Enable and Create",
                comment: "Button that enables background sessions and creates a managed SSH workspace"
            )
        }
        if backgroundSessionsEnabled {
            return String(localized: "Connect", comment: "Button that creates a managed SSH workspace")
        }
        return String(
            localized: "Enable and Connect",
            comment: "Button that enables background sessions and creates a managed SSH workspace"
        )
    }

    private var sheetTitle: String {
        if initialDestination == nil {
            return String(localized: "Connect via SSH", comment: "Title of the Connect via SSH sheet")
        }
        return String(
            localized: "Open as Managed SSH Workspace?",
            comment: "Title of the prompt shown after an ordinary SSH connection is detected"
        )
    }

    private var explanation: String {
        if initialDestination != nil {
            return String(
                localized:
                    "You connected with regular SSH. This creates a separate managed SSH workspace in “\(groupName)” and leaves the current connection open.",
                comment: "Explanation when offering to turn an observed regular SSH connection into a separate managed workspace"
            )
        }
        return String(
            localized: "Creates a managed SSH workspace in “\(groupName).”\nOpenSSH will use your existing config and credentials.",
            comment: "Explanation in the Connect via SSH sheet"
        )
    }

    private var settingsErrorMessage: String? {
        backgroundSessionsEnabled ? nil : appSettingsStore.latestError?.displayText
    }

    private func enableBackgroundSessions() -> Bool {
        appSettingsStore.terminal.update { $0.commandBridgeEnabled = true }
        return backgroundSessionsEnabled
    }
}
