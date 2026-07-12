import AwesoMuxCore
import SwiftUI
import UnicodeHygiene

struct WorkspaceGroupCreateSheet: View {
    let existingGroupNames: [String]
    let onCancel: () -> Void
    let onCreate: (String) -> Void

    @State private var draftName = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        let sanitized = SessionStore.sanitizedGroupName(draftName)
        let isMixedScript = UnicodeHygiene.hasSuspiciousScriptMixing(draftName)
        let isDuplicate = existingGroupNames.contains { existing in
            SessionStore.sanitizedGroupName(existing)
                .caseInsensitiveCompare(sanitized) == .orderedSame
        }
        let validation = validationMessage(
            sanitized: sanitized,
            isDuplicate: isDuplicate,
            isMixedScript: isMixedScript
        )
        let canCreate = !sanitized.isEmpty && !isDuplicate && !isMixedScript

        return VStack(alignment: .leading, spacing: 16) {
            Text("New Workspace Group")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Text("Name")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Group name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .focused($isNameFocused)
                .accessibilityLabel("Workspace group name")
                .onSubmit { submit(sanitized: sanitized, canCreate: canCreate) }

            if let validation {
                Text(validation)
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

                Button("Create") {
                    submit(sanitized: sanitized, canCreate: canCreate)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
                // Conditional hint on one stable button identity — an if/else
                // over two button copies resets focus mid-edit.
                .accessibilityHint(
                    validation ?? "Enter a workspace group name to enable Create",
                    isEnabled: !canCreate
                )
            }
        }
        .padding(20)
        .frame(minWidth: 360, idealWidth: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New Workspace Group")
        .onAppear {
            isNameFocused = true
        }
    }

    private func validationMessage(
        sanitized: String,
        isDuplicate: Bool,
        isMixedScript: Bool
    ) -> String? {
        if sanitized.isEmpty {
            return draftName.isEmpty
                ? "Enter a group name."
                : "Enter a visible group name."
        }

        if isMixedScript {
            return String(
                localized: "Mixing Latin with Cyrillic or Greek letters isn't allowed here — use one alphabet.",
                comment: "Validation message when a workspace group name mixes visually confusable alphabets"
            )
        }

        if isDuplicate {
            return "\"\(sanitized)\" already exists."
        }

        return nil
    }

    private func submit(sanitized: String, canCreate: Bool) {
        guard canCreate else {
            return
        }

        onCreate(sanitized)
    }
}
