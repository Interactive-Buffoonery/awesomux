import AwesoMuxConfig
import AwesoMuxCore
import SwiftUI

struct ManagedSSHOfferDestinationSheet: View {
    /// Which managed-SSH preference list a destination is being added to.
    /// `Identifiable` so the settings pane can present the add sheet with
    /// `.sheet(item:)` — the list kind then travels inside the presentation
    /// item instead of separate `@State` that can be read stale.
    enum DestinationListKind: Identifiable {
        /// Destinations that stop automatic offers.
        case neverAsk
        /// Destinations that become managed without asking.
        case alwaysManage

        var id: Self { self }

        // `String(localized:)` per branch rather than bare literals coerced to
        // `LocalizedStringKey`: both forms work at runtime, but a literal
        // hidden behind a computed property is not where the rest of this
        // codebase puts translatable copy, and only this form can carry a
        // translator comment.
        var addButtonTitle: String {
            switch self {
            case .neverAsk:
                String(
                    localized: "Add Ignored Destination…",
                    comment: "Button that opens the sheet for adding an SSH destination to the don’t-ask list"
                )
            case .alwaysManage:
                String(
                    localized: "Add Always-Managed Destination…",
                    comment: "Button that opens the sheet for adding an SSH destination to the always-manage list"
                )
            }
        }

        var sheetTitle: String {
            switch self {
            case .neverAsk:
                String(
                    localized: "Add Ignored SSH Destination",
                    comment: "Title of the sheet for adding an SSH destination to the don’t-ask list"
                )
            case .alwaysManage:
                String(
                    localized: "Add Always-Managed SSH Destination",
                    comment: "Title of the sheet for adding an SSH destination to the always-manage list"
                )
            }
        }

        /// Warns that adding here removes the destination from the other list.
        var siblingRemovalWarning: String {
            switch self {
            case .neverAsk:
                String(
                    localized:
                        "This destination is set to be managed automatically. Adding it here will stop that.",
                    comment: "Warning when adding an SSH destination to the don’t-ask list removes it from the always-manage list"
                )
            case .alwaysManage:
                String(
                    localized:
                        "This destination is on the don’t-ask list. Adding it here will remove it from that list.",
                    comment: "Warning when adding an SSH destination to the always-manage list removes it from the don’t-ask list"
                )
            }
        }

        /// Names the list on the destination text itself. Two lists of
        /// identical rows meaning opposite things read the same in linear
        /// traversal, and the section heading covers both of them.
        func rowAccessibilityLabel(destination: String) -> String {
            switch self {
            case .neverAsk:
                String(
                    localized: "\(destination), on the don’t-ask list",
                    comment: "Accessibility label for a destination row in the don’t-ask list"
                )
            case .alwaysManage:
                String(
                    localized: "\(destination), managed automatically",
                    comment: "Accessibility label for a destination row in the always-manage list"
                )
            }
        }

        func removedAnnouncement(destination: String) -> String {
            switch self {
            case .neverAsk:
                String(
                    localized: "Removed \(destination) from the don’t-ask list",
                    comment: "Announced after removing an SSH destination from the don’t-ask list"
                )
            case .alwaysManage:
                String(
                    localized: "Removed \(destination) from the always-manage list",
                    comment: "Announced after removing an SSH destination from the always-manage list"
                )
            }
        }

        /// Names the list as well as the destination. Both lists render
        /// identical rows with identical remove buttons and mean opposite
        /// things, so "Remove build-box" alone leaves a screen-reader user
        /// relying on how far back the section heading was.
        func removeAccessibilityLabel(destination: String) -> String {
            switch self {
            case .neverAsk:
                String(
                    localized: "Remove \(destination) from the don’t-ask list",
                    comment: "Accessibility label for the button removing an SSH destination from the don’t-ask list"
                )
            case .alwaysManage:
                String(
                    localized: "Remove \(destination) from the always-manage list",
                    comment: "Accessibility label for the button removing an SSH destination from the always-manage list"
                )
            }
        }
    }

    let listKind: DestinationListKind

    @Environment(AppSettingsStore.self) private var appSettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var destination = ""
    @State private var submissionError: String?
    @FocusState private var destinationFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(listKind.sheetTitle)
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

            if let notice = siblingRemovalNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    private var storedDestinations: [String] {
        let workspaces = appSettingsStore.workspaces.value
        switch listKind {
        case .neverAsk:
            return workspaces.managedSSHOfferIgnoredDestinations
        case .alwaysManage:
            return ManagedSSHOfferPolicy.sortedAlwaysManagedDestinations(in: workspaces)
        }
    }

    private var validationMessage: String? {
        if let message = SSHWorkspaceDestinationValidation.message(for: destination) {
            return message
        }
        guard let target = SSHWorkspaceDestinationValidation.target(from: destination) else {
            return nil
        }
        if storedDestinations.contains(where: {
            SSHWorkspaceDestinationValidation.target(from: $0)?.sshDestination == target.sshDestination
        }) {
            return String(
                localized: "This destination is already on the list.",
                comment: "Error shown when a managed SSH destination is added twice"
            )
        }
        return nil
    }

    /// Disclosure, not refusal. The two lists are kept disjoint, so adding here
    /// deletes the entry over there — including, for an always-managed entry,
    /// the persistence owner that can only be set from a live connect prompt.
    /// The duplicate check above looks only at the list being added to, so
    /// without this the field looks clean right up until the other row
    /// disappears.
    ///
    /// Deliberately not part of `validationMessage`: that also gates the Add
    /// button, so returning it there left a sentence promising a move the
    /// button could no longer perform, and made a destination on the opposite
    /// list impossible to move from this sheet at all.
    private var siblingRemovalNotice: String? {
        guard SSHWorkspaceDestinationValidation.message(for: destination) == nil,
            let target = SSHWorkspaceDestinationValidation.target(from: destination),
            siblingDestinations.contains(where: {
                SSHWorkspaceDestinationValidation.target(from: $0)?.sshDestination
                    == target.sshDestination
            })
        else {
            return nil
        }
        return listKind.siblingRemovalWarning
    }

    /// The list this destination will be removed from if it is added here.
    private var siblingDestinations: [String] {
        let workspaces = appSettingsStore.workspaces.value
        switch listKind {
        case .neverAsk:
            return ManagedSSHOfferPolicy.sortedAlwaysManagedDestinations(in: workspaces)
        case .alwaysManage:
            return workspaces.managedSSHOfferIgnoredDestinations
        }
    }

    private var validatedDestination: RemoteTarget? {
        SSHWorkspaceDestinationValidation.target(from: destination)
    }

    private func addDestination() {
        guard validatedDestination != nil, validationMessage == nil else { return }
        submissionError = nil
        // Same reasoning as the connect sheet's Remember actions, and the same
        // guard: dismissing on an unwritten preference reads as success in
        // both channels, and the Settings banner that would disclose it is
        // behind this modal.
        if let reason = ManagedSSHPreferenceWriteGuard.blockedReason(store: appSettingsStore) {
            submissionError = reason
            TerminalAccessibilityAnnouncer.announceSettingsError(submissionError)
            return
        }
        var result: ManagedSSHOfferPolicy.AddResult = .invalid
        appSettingsStore.workspaces.update {
            switch listKind {
            case .neverAsk:
                result = ManagedSSHOfferPolicy.addIgnoredDestination(destination, to: &$0)
            case .alwaysManage:
                result = ManagedSSHOfferPolicy.addAlwaysManagedDestination(destination, to: &$0)
            }
        }
        guard case .added(let addedDestination) = result,
            storedDestinations.contains(addedDestination)
        else {
            submissionError =
                appSettingsStore.latestError?.displayText
                ?? String(
                    localized: "Couldn’t save this destination.",
                    comment: "Error shown when awesoMux cannot save a managed SSH destination"
                )
            TerminalAccessibilityAnnouncer.announceSettingsError(submissionError)
            return
        }
        dismiss()
    }
}
