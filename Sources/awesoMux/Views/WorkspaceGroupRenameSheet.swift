import AwesoMuxCore
import SwiftUI

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
        let nameDraft = WorkspaceGroupNameDraft(
            typedName: draftName,
            existingGroupNames: existingGroups.lazy
                .filter { $0.id != currentGroupID }
                .map(\.name)
        )

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
                .onSubmit { save(nameDraft) }

            if let validation = nameDraft.validationMessage {
                Text(validation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let feedback = nameDraft.sanitizationFeedback {
                Label(feedback, systemImage: "info.circle")
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
                    save(nameDraft)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!nameDraft.canSubmit)

                if nameDraft.canSubmit {
                    saveButton
                } else {
                    saveButton
                        .accessibilityHint(
                            nameDraft.validationMessage ?? "Enter a workspace group name to enable Save"
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

    private func save(_ nameDraft: WorkspaceGroupNameDraft) {
        guard nameDraft.canSubmit else {
            return
        }

        guard nameDraft.sanitizedName != groupName else {
            onCancel()
            return
        }

        onSave(nameDraft.sanitizedName)
    }
}
