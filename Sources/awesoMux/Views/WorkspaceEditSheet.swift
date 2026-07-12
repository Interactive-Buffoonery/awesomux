import AwesoMuxCore
import SwiftUI

struct WorkspaceEditSheet: View {
    let title: String
    let onCancel: () -> Void
    let onSave: (String) -> Void
    @State private var draftTitle: String
    @State private var isSaving = false
    @FocusState private var isTitleFocused: Bool

    init(
        title: String,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) -> Void
    ) {
        self.title = title
        self.onCancel = onCancel
        self.onSave = onSave
        _draftTitle = State(initialValue: title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename '\(title)'")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Text("Name")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Workspace name", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .focused($isTitleFocused)
                .accessibilityLabel("Workspace name")
                .onSubmit(save)

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                let saveButton = Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedTitle.isEmpty)

                if trimmedTitle.isEmpty {
                    saveButton
                        .accessibilityHint("Enter a workspace name to enable Save")
                } else {
                    saveButton
                }
            }
        }
        .padding(20)
        .frame(minWidth: 360, idealWidth: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rename Workspace")
        .onAppear {
            isTitleFocused = true
        }
    }

    private var trimmedTitle: String {
        SessionStore.sanitizedTitle(draftTitle)
    }

    private func save() {
        guard !isSaving, !trimmedTitle.isEmpty else {
            return
        }

        guard trimmedTitle != title else {
            onCancel()
            return
        }

        isSaving = true
        onSave(trimmedTitle)
    }
}
