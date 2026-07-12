import AwesoMuxCore
import SwiftUI

struct PaneEditSheet: View {
    let title: String
    let canReset: Bool
    let onCancel: () -> Void
    let onReset: () -> Void
    let onSave: (String) -> Void
    @State private var draftTitle: String
    @FocusState private var isTitleFocused: Bool

    init(
        title: String,
        canReset: Bool,
        onCancel: @escaping () -> Void,
        onReset: @escaping () -> Void,
        onSave: @escaping (String) -> Void
    ) {
        self.title = title
        self.canReset = canReset
        self.onCancel = onCancel
        self.onReset = onReset
        self.onSave = onSave
        _draftTitle = State(initialValue: title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Pane")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Text("Name")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Pane name", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .focused($isTitleFocused)
                .accessibilityLabel("Pane name")
                .onSubmit(save)

            HStack {
                // Parity with the inline editor / context menu / agent path,
                // which can all reset to the live terminal title. Without this the
                // palette sheet would be the only rename path that can't reset
                // (cross-task review).
                Button("Reset to Terminal Title") { onReset() }
                    .disabled(!canReset)

                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedTitle.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 360, idealWidth: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rename Pane")
        .onAppear { isTitleFocused = true }
    }

    private var trimmedTitle: String {
        SessionStore.sanitizedTitle(draftTitle)
    }

    private func save() {
        // No re-entrancy latch needed: onSave dismisses the sheet immediately
        // (the parent clears paneEditRequest), so the view is gone before a
        // second submit can land (review finding).
        guard !trimmedTitle.isEmpty else { return }
        guard trimmedTitle != title else { onCancel(); return }
        onSave(trimmedTitle)
    }
}
