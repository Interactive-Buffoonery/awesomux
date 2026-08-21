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
    let origin: SSHWorkspaceConnectOrigin
    let onCancel: () -> Void
    let onConnect: (SSHExecution) -> Bool

    @Environment(AppSettingsStore.self) private var appSettingsStore
    @State private var destination: String
    @State private var sessionName = ""
    @State private var submission = SSHWorkspaceConnectionSubmission()
    @State private var preferenceErrorMessage: String?
    @FocusState private var isFocused: Bool

    init(
        groupName: String?,
        initialDestination: String? = nil,
        origin: SSHWorkspaceConnectOrigin,
        onCancel: @escaping () -> Void,
        onConnect: @escaping (SSHExecution) -> Bool
    ) {
        self.groupName = groupName
        self.initialDestination = initialDestination
        self.origin = origin
        self.onCancel = onCancel
        self.onConnect = onConnect
        _destination = State(initialValue: initialDestination ?? "")
    }

    var body: some View {
        let execution = SSHWorkspaceConnectFields.execution(
            destination: destination,
            sessionName: sessionName
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
                .accessibilityHint(
                    String(
                        localized: "Optional. Names a session the remote host keeps running with its own amx or zmx",
                        comment: "Accessibility hint for the remote session name field in the Connect via SSH sheet"
                    )
                )
                .onSubmit { connect(execution) }
            // A name is a persistence-owner switch, not a label, and the sheet
            // used to say so only by revealing a path field. Now that the
            // backend resolves itself, this caption is the only disclosure —
            // and it has to arrive before Connect, not after a failed attach.
            if declaresRemoteSession {
                Text(remoteSessionExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = validationMessage ?? preferenceErrorMessage ?? settingsErrorMessage ?? submission.errorMessage {
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
                if origin.showsRememberActions {
                    rememberMenu
                }
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
    }

    /// Placeholder example, deliberately not localized: a session name is
    /// restricted to `[A-Za-z0-9._-]`, so it does not change by language.
    private static let sessionNamePlaceholder = "my-session"

    private var remoteSessionExplanation: String {
        guard let host = SSHWorkspaceDestinationValidation.target(from: destination)?.host else {
            return String(
                localized:
                    "Named, the remote host keeps this session running with its own amx or zmx, and awesoMux finds it there. Leave empty to keep the session on this Mac instead.",
                comment: "Caption explaining what naming a remote session does, before a destination has been entered"
            )
        }
        return String(
            localized:
                "\(host) keeps this session running with its own amx or zmx, and awesoMux finds it there. Leave empty to keep the session on this Mac instead.",
            comment: "Caption explaining what naming a remote session does. The argument is the destination host"
        )
    }

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

    private var rememberMenu: some View {
        Menu("Remember…") {
            Button("Always Manage This Destination") {
                alwaysManageThisDestination()
            }
            Button("Always Manage Any Destination") {
                alwaysManageAnyDestination()
            }
            Divider()
            Button("Never Ask for This Destination") {
                neverAskForThisDestination()
            }
            Button("Never Ask for Any Destination") {
                neverAskForAnyDestination()
            }
            Divider()
            Button("Keep Asking") {}
        }
    }

    /// Saving the preference and connecting are one intent: "always" answers
    /// this prompt too. A failed save keeps the sheet open instead, mirroring
    /// how the never-ask actions behave when persistence fails.
    private func alwaysManageThisDestination() {
        preferenceErrorMessage = nil
        appSettingsStore.workspaces.update {
            _ = ManagedSSHOfferPolicy.addAlwaysManagedDestination(destination, to: &$0)
        }
        guard
            let target = SSHWorkspaceDestinationValidation.target(from: destination),
            ManagedSSHOfferPolicy.isAlwaysManaged(
                target: target,
                config: appSettingsStore.workspaces.value
            )
        else {
            showPreferenceSaveError()
            return
        }
        connect(SSHWorkspaceConnectFields.execution(destination: destination, sessionName: sessionName))
    }

    private func alwaysManageAnyDestination() {
        preferenceErrorMessage = nil
        appSettingsStore.workspaces.update { $0.managedSSHAlwaysManageAllDestinations = true }
        guard appSettingsStore.workspaces.value.managedSSHAlwaysManageAllDestinations else {
            showPreferenceSaveError()
            return
        }
        connect(SSHWorkspaceConnectFields.execution(destination: destination, sessionName: sessionName))
    }

    private func neverAskForThisDestination() {
        preferenceErrorMessage = nil
        appSettingsStore.workspaces.update {
            _ = ManagedSSHOfferPolicy.addIgnoredDestination(destination, to: &$0)
        }
        guard
            let target = SSHWorkspaceDestinationValidation.target(from: destination),
            ManagedSSHOfferPolicy.isIgnored(
                target: target,
                config: appSettingsStore.workspaces.value
            )
        else {
            showPreferenceSaveError()
            return
        }
        onCancel()
    }

    private func neverAskForAnyDestination() {
        preferenceErrorMessage = nil
        appSettingsStore.workspaces.update { $0.managedSSHOffersEnabled = false }
        guard !appSettingsStore.workspaces.value.managedSSHOffersEnabled else {
            showPreferenceSaveError()
            return
        }
        onCancel()
    }

    private func showPreferenceSaveError() {
        preferenceErrorMessage =
            appSettingsStore.latestError?.displayText
            ?? String(
                localized: "Couldn’t save the managed SSH setting.",
                comment: "Error shown when awesoMux cannot save a managed SSH offer preference"
            )
        TerminalAccessibilityAnnouncer.announceSettingsError(preferenceErrorMessage)
    }

    private var declaresRemoteSession: Bool {
        SSHWorkspaceConnectFields.declaresRemoteSession(sessionName: sessionName)
    }

    private var fieldValidationMessage: String? {
        SSHWorkspaceDestinationValidation.message(for: destination)
            ?? SSHWorkspaceConnectFields.sessionNameMessage(for: sessionName)
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
