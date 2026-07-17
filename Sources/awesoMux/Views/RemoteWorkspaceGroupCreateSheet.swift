import AwesoMuxConfig
import AwesoMuxCore
import SwiftUI

struct RemoteWorkspaceGroupCreateSheet: View {
    let onCancel: () -> Void
    let onCreate: (_ name: String, _ target: RemoteTarget) -> Void

    @Environment(AppSettingsStore.self) private var appSettingsStore
    @State private var draftName = ""
    @State private var draftHost = ""
    @FocusState private var isHostFocused: Bool

    var body: some View {
        // Shared validator, not bare RemoteTarget(parsing:): option-like
        // destinations must be rejected at every creation boundary, and the
        // store guard returning nil would otherwise leave a dead Create button.
        let target = SSHWorkspaceDestinationValidation.target(from: draftHost)
        let canCreate = target != nil

        return VStack(alignment: .leading, spacing: 16) {
            Text("New Remote Workspace Group")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Text("Name")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Group name (optional)", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .accessibilityLabel("Workspace group name")
                .onSubmit { submit(target: target, canCreate: canCreate) }

            Text("Host")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("user@host", text: $draftHost)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .focused($isHostFocused)
                .accessibilityLabel("Remote host")
                .onSubmit { submit(target: target, canCreate: canCreate) }

            if let message = SSHWorkspaceDestinationValidation.message(for: draftHost) ?? settingsErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !backgroundSessionsEnabled {
                Label(
                    "Managed SSH requires background terminal sessions. awesoMux will turn them on when you create the group.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button(primaryButtonLabel) {
                    submit(target: target, canCreate: canCreate)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
                // Conditional hint on one stable button identity — an if/else
                // over two button copies resets focus mid-edit.
                .accessibilityHint(
                    SSHWorkspaceDestinationValidation.message(for: draftHost)
                        ?? String(
                            localized: "Enter a host to enable Create",
                            comment: "Accessibility hint for the disabled Create button in the New Remote Workspace Group sheet"),
                    isEnabled: !canCreate
                )
            }
        }
        .padding(20)
        .frame(minWidth: 360, idealWidth: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New Remote Workspace Group")
        .onAppear {
            isHostFocused = true
        }
    }

    private func submit(target: RemoteTarget?, canCreate: Bool) {
        guard canCreate, let target else {
            return
        }
        guard backgroundSessionsEnabled || enableBackgroundSessions() else { return }
        onCreate(draftName, target)
    }

    private var backgroundSessionsEnabled: Bool {
        appSettingsStore.terminal.value.commandBridgeEnabled
    }

    private var primaryButtonLabel: String {
        if backgroundSessionsEnabled {
            return String(localized: "Create", comment: "Button that creates a remote workspace group")
        }
        return String(
            localized: "Enable and Create",
            comment: "Button that enables background sessions and creates a remote workspace group"
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
