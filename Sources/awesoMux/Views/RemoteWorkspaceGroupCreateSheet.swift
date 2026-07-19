import AwesoMuxConfig
import AwesoMuxCore
import SwiftUI

struct RemoteWorkspaceGroupCreateSheet: View {
    let existingGroupNames: [String]
    let onCancel: () -> Void
    let onCreate: (_ name: String, _ target: RemoteTarget) -> Void

    @Environment(AppSettingsStore.self) private var appSettingsStore
    @State private var draftName = ""
    @State private var draftHost = ""
    @State private var adjustmentAnnouncementGate = WorkspaceGroupNameAdjustmentAnnouncementGate()
    @FocusState private var isHostFocused: Bool

    var body: some View {
        // Shared validator, not bare RemoteTarget(parsing:): option-like
        // destinations must be rejected at every creation boundary, and the
        // store guard returning nil would otherwise leave a dead Create button.
        let target = SSHWorkspaceDestinationValidation.target(from: draftHost)
        let nameDraft = WorkspaceGroupNameDraft(
            typedName: draftName,
            existingGroupNames: existingGroupNames,
            allowsEmptyName: true
        )
        let canCreate = target != nil && nameDraft.canSubmit

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
                .onSubmit { submit(nameDraft: nameDraft, target: target) }
                .onChange(of: draftName) { _, _ in
                    adjustmentAnnouncementGate.editingChanged()
                }

            WorkspaceGroupNameFeedback(draft: nameDraft)

            Text("Host")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("user@host", text: $draftHost)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .focused($isHostFocused)
                .accessibilityLabel("Remote host")
                .onSubmit { submit(nameDraft: nameDraft, target: target) }

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
                    submit(nameDraft: nameDraft, target: target)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
                // Conditional hint on one stable button identity — an if/else
                // over two button copies resets focus mid-edit.
                .accessibilityHint(
                    nameDraft.validationMessage
                        ?? SSHWorkspaceDestinationValidation.message(for: draftHost)
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

    private func submit(nameDraft: WorkspaceGroupNameDraft, target: RemoteTarget?) {
        guard nameDraft.canSubmit, let target else {
            return
        }
        guard backgroundSessionsEnabled || enableBackgroundSessions() else { return }
        adjustmentAnnouncementGate.announceIfNeeded(for: nameDraft)
        onCreate(nameDraft.sanitizedName, target)
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
