import AwesoMuxCore
import SwiftUI

struct WorkspaceGroupCreateSheet: View {
    let existingGroupNames: [String]
    let onCancel: () -> Void
    let onCreate: (String) -> Void

    @State private var draftName = ""
    @State private var adjustmentAnnouncementGate = WorkspaceGroupNameAdjustmentAnnouncementGate()
    @FocusState private var isNameFocused: Bool

    var body: some View {
        let nameDraft = WorkspaceGroupNameDraft(
            typedName: draftName,
            existingGroupNames: existingGroupNames
        )

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
                .onSubmit { submit(nameDraft) }
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

                Button("Create") {
                    submit(nameDraft)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!nameDraft.canSubmit)
                // Conditional hint on one stable button identity — an if/else
                // over two button copies resets focus mid-edit.
                .accessibilityHint(
                    nameDraft.validationMessage ?? "Enter a workspace group name to enable Create",
                    isEnabled: !nameDraft.canSubmit
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

    private func submit(_ nameDraft: WorkspaceGroupNameDraft) {
        guard nameDraft.canSubmit else {
            return
        }

        adjustmentAnnouncementGate.announceIfNeeded(for: nameDraft)
        onCreate(nameDraft.sanitizedName)
    }
}
