import AwesoMuxCore
import SwiftUI

struct WorkspaceGroupRenameSheet: View {
    let groupName: String
    let existingGroups: [(id: SessionGroup.ID, name: String)]
    let currentGroupID: SessionGroup.ID
    let onCancel: () -> Void
    let onSave: (String) -> Void

    @State private var draftName: String
    @State private var adjustmentAnnouncementGate = WorkspaceGroupNameAdjustmentAnnouncementGate()
    @FocusState private var isNameFocused: Bool

    init(
        groupName: String,
        existingGroups: [(id: SessionGroup.ID, name: String)],
        currentGroupID: SessionGroup.ID,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) -> Void
    ) {
        // Clamp the incoming name the same way typed input is clamped. A saved
        // name can be longer than the clamp: sanitization bounds its *input* at
        // the same 4096 scalars, but NFKC expands, and 80 clusters of a base
        // plus 50 U+0344 fold to 4960 scalars in exactly 80 characters — which
        // the 80-character clip keeps whole. Seeding the draft from such a name
        // unclamped would leave `save()` comparing a clamped draft against an
        // unclamped name, so an untouched rename would commit a truncation the
        // user never typed.
        //
        // Untested: this init is private to the View with no seam, so nothing
        // fails if the clamp is dropped. The premise it rests on — that a saved
        // name can be longer than the clamp — is pinned by
        // `sanitizedNameCanExceedTheInputClamp`.
        let clampedGroupName = WorkspaceGroupNameDraft.clampedInput(groupName)
        self.groupName = clampedGroupName
        self.existingGroups = existingGroups
        self.currentGroupID = currentGroupID
        self.onCancel = onCancel
        self.onSave = onSave
        _draftName = State(initialValue: clampedGroupName)
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

            TextField(
                "Group name",
                text: Binding(
                    get: { draftName },
                    set: { draftName = WorkspaceGroupNameDraft.clampedInput($0) }
                )
            )
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .focused($isNameFocused)
                .accessibilityLabel("Workspace group name")
                .onSubmit { save(nameDraft) }
                .onChange(of: draftName) { _, _ in
                    adjustmentAnnouncementGate.editingChanged()
                }

            WorkspaceGroupNameFeedback(draft: nameDraft)

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

        adjustmentAnnouncementGate.announceIfNeeded(for: nameDraft)
        onSave(nameDraft.sanitizedName)
    }
}
