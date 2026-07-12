import AwesoMuxCore
import SwiftUI
import UnicodeHygiene

struct WorkspaceGroupRenameSheet: View {
    let groupName: String
    let existingGroups: [(id: SessionGroup.ID, name: String)]
    let currentGroupID: SessionGroup.ID
    let onCancel: () -> Void
    let onSave: (String) -> Void

    @State private var draftName: String
    @FocusState private var isNameFocused: Bool

    init(
        groupName: String,
        existingGroups: [(id: SessionGroup.ID, name: String)],
        currentGroupID: SessionGroup.ID,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) -> Void
    ) {
        self.groupName = groupName
        self.existingGroups = existingGroups
        self.currentGroupID = currentGroupID
        self.onCancel = onCancel
        self.onSave = onSave
        _draftName = State(initialValue: groupName)
    }

    var body: some View {
        let sanitized = SessionStore.sanitizedGroupName(draftName)
        let isMixedScript = UnicodeHygiene.hasSuspiciousScriptMixing(draftName)
        let isDuplicate = existingGroups.contains { existing in
            existing.id != currentGroupID
                && SessionStore.sanitizedGroupName(existing.name)
                    .caseInsensitiveCompare(sanitized) == .orderedSame
        }
        let validation = validationMessage(
            sanitized: sanitized,
            isDuplicate: isDuplicate,
            isMixedScript: isMixedScript
        )
        let canSave = !sanitized.isEmpty && !isDuplicate && !isMixedScript

        return VStack(alignment: .leading, spacing: 16) {
            Text("Rename '\(groupName)'")
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
                .onSubmit { save(sanitized: sanitized, canSave: canSave) }

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

                let saveButton = Button("Save") {
                    save(sanitized: sanitized, canSave: canSave)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)

                if canSave {
                    saveButton
                } else {
                    saveButton
                        .accessibilityHint(
                            validation ?? "Enter a workspace group name to enable Save"
                        )
                }
            }
        }
        .padding(20)
        .frame(minWidth: 360, idealWidth: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rename Workspace Group")
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

    private func save(sanitized: String, canSave: Bool) {
        guard canSave else {
            return
        }

        guard sanitized != groupName else {
            onCancel()
            return
        }

        onSave(sanitized)
    }
}
