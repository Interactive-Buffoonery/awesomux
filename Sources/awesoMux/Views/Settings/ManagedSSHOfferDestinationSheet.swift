import AwesoMuxConfig
import AwesoMuxCore
import SwiftUI

struct ManagedSSHOfferDestinationSheet: View {
    @Environment(AppSettingsStore.self) private var appSettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var destination = ""
    @State private var submissionError: String?
    @FocusState private var destinationFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add SSH Destination")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Text("Enter an OpenSSH alias or destination.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("my-server", text: $destination)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .focused($destinationFocused)
                .accessibilityLabel("SSH destination")
                .onSubmit(addDestination)

            if let message = validationMessage ?? submissionError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: addDestination)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validatedDestination == nil || validationMessage != nil)
            }
        }
        .padding(20)
        .frame(minWidth: 360, idealWidth: 420)
        .onAppear { destinationFocused = true }
    }

    private var validationMessage: String? {
        if let message = SSHWorkspaceDestinationValidation.message(for: destination) {
            return message
        }
        guard let target = SSHWorkspaceDestinationValidation.target(from: destination) else {
            return nil
        }
        let ignored = appSettingsStore.workspaces.value.managedSSHOfferIgnoredDestinations
        if ignored.contains(where: {
            SSHWorkspaceDestinationValidation.target(from: $0)?.sshDestination == target.sshDestination
        }) {
            return String(
                localized: "This destination is already on the list.",
                comment: "Error shown when an ignored managed SSH destination is added twice"
            )
        }
        return nil
    }

    private var validatedDestination: RemoteTarget? {
        SSHWorkspaceDestinationValidation.target(from: destination)
    }

    private func addDestination() {
        guard validatedDestination != nil, validationMessage == nil else { return }
        submissionError = nil
        var result: ManagedSSHOfferPolicy.AddResult = .invalid
        appSettingsStore.workspaces.update {
            result = ManagedSSHOfferPolicy.addIgnoredDestination(destination, to: &$0)
        }
        guard case .added(let addedDestination) = result,
            appSettingsStore.workspaces.value.managedSSHOfferIgnoredDestinations.contains(addedDestination)
        else {
            submissionError =
                appSettingsStore.latestError?.displayText
                ?? String(
                    localized: "Couldn’t save this destination.",
                    comment: "Error shown when awesoMux cannot save an ignored managed SSH destination"
                )
            TerminalAccessibilityAnnouncer.announceSettingsError(submissionError)
            return
        }
        dismiss()
    }
}
