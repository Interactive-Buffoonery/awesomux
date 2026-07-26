import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import SwiftUI

struct SSHWorkspaceConnectionSubmission {
    private(set) var isConnecting = false
    private(set) var errorMessage: String?

    /// `isCommandBridgeEnabled` / `enableCommandBridge` gate local-amx
    /// submissions only. A remote-owned session runs with no local `amx` daemon
    /// in front of it, so it must neither require the global command-bridge
    /// setting nor turn it on behind the user's back.
    mutating func submit(
        execution: SSHExecution?,
        isCommandBridgeEnabled: Bool,
        enableCommandBridge: () -> Bool,
        connect: (SSHExecution) -> Bool,
        announce: (String) -> Void
    ) {
        guard !isConnecting, let execution else { return }
        if execution.persistenceOwner == .localAmx, !isCommandBridgeEnabled, !enableCommandBridge() {
            return
        }
        isConnecting = true
        errorMessage = nil
        guard connect(execution) else {
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
    let onConnect: (SSHExecution) -> Bool

    @Environment(AppSettingsStore.self) private var appSettingsStore
    @State private var destination: String
    @State private var sessionName = ""
    @State private var remoteExecutablePath = ""
    @State private var submission = SSHWorkspaceConnectionSubmission()
    @FocusState private var isFocused: Bool

    init(
        groupName: String?,
        initialDestination: String? = nil,
        onCancel: @escaping () -> Void,
        onConnect: @escaping (SSHExecution) -> Bool
    ) {
        self.groupName = groupName
        self.initialDestination = initialDestination
        self.onCancel = onCancel
        self.onConnect = onConnect
        _destination = State(initialValue: initialDestination ?? "")
    }

    var body: some View {
        let execution = SSHWorkspaceConnectFields.execution(
            destination: destination,
            sessionName: sessionName,
            remoteExecutablePath: remoteExecutablePath
        )
        let validationMessage = fieldValidationMessage
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
                .onSubmit { connect(execution) }
            Text("Remote session name (optional)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(Self.sessionNamePlaceholder, text: $sessionName)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .accessibilityLabel("Remote session name")
                .accessibilityHint("Optional. Names a zmx session the remote host keeps running")
                .onSubmit { connect(execution) }
            if declaresRemoteSession {
                Text("zmx path (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(Self.remoteExecutablePathPlaceholder, text: $remoteExecutablePath)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                    .accessibilityLabel("Remote zmx path")
                    .accessibilityHint("Optional. Leave empty to run zmx from the remote PATH")
                    .onSubmit { connect(execution) }
            }
            if let message = validationMessage ?? settingsErrorMessage ?? submission.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !backgroundSessionsEnabled, !declaresRemoteSession {
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
                    connect(execution)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(execution == nil || submission.isConnecting)
                .accessibilityHint(
                    validationMessage
                        ?? String(
                            localized: "Enter a destination to enable Connect",
                            comment: "Accessibility hint for the disabled Connect button in the Connect via SSH sheet"
                        ),
                    isEnabled: execution == nil
                )
            }
        }
        .padding(20)
        .frame(minWidth: 360, idealWidth: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(sheetTitle)
        .onAppear { isFocused = true }
        // Clearing the session name hides the path field; its text would
        // otherwise survive unseen and either revive on re-entry or be silently
        // dropped by `execution(...)` on submit.
        .onChange(of: declaresRemoteSession) { _, declares in
            if !declares { remoteExecutablePath = "" }
        }
    }

    /// Placeholder examples, deliberately not localized: a session name is
    /// restricted to `[A-Za-z0-9._-]` and a path is a path, so neither example
    /// changes by language.
    private static let sessionNamePlaceholder = "my-session"
    private static let remoteExecutablePathPlaceholder = "/usr/local/bin/zmx"

    private func connect(_ execution: SSHExecution?) {
        submission.submit(
            execution: execution,
            isCommandBridgeEnabled: backgroundSessionsEnabled,
            enableCommandBridge: enableBackgroundSessions,
            connect: onConnect,
            announce: {
                TerminalAccessibilityAnnouncer.announce($0, priority: .high)
            }
        )
    }

    private var declaresRemoteSession: Bool {
        SSHWorkspaceConnectFields.declaresRemoteSession(sessionName: sessionName)
    }

    private var fieldValidationMessage: String? {
        SSHWorkspaceDestinationValidation.message(for: destination)
            ?? SSHWorkspaceConnectFields.sessionNameMessage(for: sessionName)
            ?? (declaresRemoteSession
                ? SSHWorkspaceConnectFields.remoteExecutablePathMessage(for: remoteExecutablePath) : nil)
    }

    private var backgroundSessionsEnabled: Bool {
        appSettingsStore.terminal.value.commandBridgeEnabled
    }

    /// A remote-owned session never turns background sessions on, so its button
    /// must not promise to.
    private var primaryButtonLabel: String {
        if initialDestination != nil {
            if backgroundSessionsEnabled || declaresRemoteSession {
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
        if backgroundSessionsEnabled || declaresRemoteSession {
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
        backgroundSessionsEnabled || declaresRemoteSession ? nil : appSettingsStore.latestError?.displayText
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
