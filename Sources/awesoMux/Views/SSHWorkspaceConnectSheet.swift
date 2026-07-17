import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import SwiftUI

struct SSHWorkspaceConnectionSubmission {
    private(set) var isConnecting = false
    private(set) var errorMessage: String?

    mutating func submit(
        target: RemoteTarget?,
        connect: (RemoteTarget) -> Bool,
        announce: (String) -> Void
    ) {
        guard !isConnecting, let target else { return }
        isConnecting = true
        errorMessage = nil
        guard connect(target) else {
            isConnecting = false
            let message = String(
                localized: "Couldn’t connect. The workspace is no longer available.",
                comment: "Error shown when a managed SSH connection request targets a workspace that no longer exists"
            )
            errorMessage = message
            announce(message)
            return
        }
    }
}

struct SSHWorkspaceConnectSheet: View {
    let groupName: String?
    let initialDestination: String?
    let onCancel: () -> Void
    let onConnect: (RemoteTarget) -> Bool

    @Environment(AppSettingsStore.self) private var appSettingsStore
    @State private var destination: String
    @State private var submission = SSHWorkspaceConnectionSubmission()
    @FocusState private var isFocused: Bool

    init(
        groupName: String?,
        initialDestination: String? = nil,
        onCancel: @escaping () -> Void,
        onConnect: @escaping (RemoteTarget) -> Bool
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
            if let message = validationMessage ?? settingsErrorMessage ?? submission.errorMessage {
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
                .disabled(target == nil || submission.isConnecting)
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
        submission.submit(
            target: target,
            connect: onConnect,
            announce: {
                TerminalAccessibilityAnnouncer.announce($0, priority: .high)
            }
        )
    }

    private var backgroundSessionsEnabled: Bool {
        appSettingsStore.terminal.value.commandBridgeEnabled
    }

    private var primaryButtonLabel: String {
        if initialDestination != nil {
            if backgroundSessionsEnabled {
                return String(
                    localized: "Reconnect as Managed",
                    comment: "Button that reconnects an ordinary SSH pane as managed"
                )
            }
            return String(
                localized: "Enable and Reconnect",
                comment: "Button that enables background sessions and reconnects an SSH pane as managed"
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
            localized: "Make This Workspace Managed?",
            comment: "Title of the prompt to reconnect an ordinary SSH pane as managed"
        )
    }

    private var explanation: String {
        if initialDestination != nil {
            return String(
                localized:
                    "This restarts the current SSH connection through awesoMux. This workspace and its other panes stay open.",
                comment: "Explanation when offering to reconnect an ordinary SSH pane as managed"
            )
        }
        guard let groupName else { return "" }
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
        guard backgroundSessionsEnabled else {
            TerminalAccessibilityAnnouncer.announceSettingsError(settingsErrorMessage)
            return false
        }
        return true
    }
}
