import AwesoMuxCore
import DesignSystem
import SwiftUI

struct DocumentNoteSheet: View {
    let note: PlanAnnotation?
    /// Write callbacks report success; the sheet closes (and drops draft
    /// state) only when the write landed, so a stale-source failure keeps the
    /// user's typing on screen next to the explanatory alert.
    let onAdd: (String) -> Bool
    let onEdit: (String, String) -> Bool
    let onSetStatus: (String, PlanAnnotationStatus) -> Bool
    let onDelete: (String) -> Bool
    let onClose: () -> Void
    var allowsEditing = true

    @State private var isEditing: Bool
    @State private var draft: String

    init(
        note: PlanAnnotation?,
        onAdd: @escaping (String) -> Bool,
        onEdit: @escaping (String, String) -> Bool,
        onSetStatus: @escaping (String, PlanAnnotationStatus) -> Bool,
        onDelete: @escaping (String) -> Bool,
        onClose: @escaping () -> Void,
        allowsEditing: Bool = true
    ) {
        self.note = note
        self.onAdd = onAdd
        self.onEdit = onEdit
        self.onSetStatus = onSetStatus
        self.onDelete = onDelete
        self.onClose = onClose
        self.allowsEditing = allowsEditing
        _isEditing = State(initialValue: note == nil && allowsEditing)
        _draft = State(initialValue: note?.payload ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.aw.border2)
            content
        }
        .frame(width: 620)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Document note")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Document Note")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.aw.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            // Esc parity with the app's other sheets. While editing, the
            // editor's Cancel owns Esc (cancel the edit, not the sheet).
            .keyboardShortcut(isEditing ? nil : .cancelAction)
            .foregroundStyle(Color.aw.text2)
            .help("Close document note")
            .accessibilityLabel("Close document note")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if isEditing {
            MultilineDocumentNoteEditor(
                title: note == nil ? "Add document note" : "Edit document note",
                draft: $draft,
                submitTitle: note == nil ? "Add Note" : "Save Changes",
                onCancel: note == nil ? onClose : {
                    draft = note?.payload ?? ""
                    isEditing = false
                },
                onSubmit: save
            )
        } else if let note {
            VStack(alignment: .leading, spacing: 16) {
                ScrollView {
                    Text(note.payload.isEmpty ? "(No note)" : note.payload)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.aw.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                }
                // Bound the viewer: a sheet sizes to fitting content, and an
                // unbounded ScrollView collapses (or balloons) in that measure.
                .frame(minHeight: 160, maxHeight: 380)

                if allowsEditing {
                    Divider().overlay(Color.aw.border2)
                    HStack(spacing: 10) {
                        Button("Delete", role: .destructive) {
                            if onDelete(note.id) {
                                onClose()
                            }
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button("Edit") {
                            draft = note.payload
                            isEditing = true
                        }
                        .buttonStyle(.bordered)

                        Button {
                            // Close on success: the sheet shows the note as of
                            // when it opened, so staying open after a status
                            // write would display a stale status.
                            if onSetStatus(note.id, note.status == .open ? .resolved : .open) {
                                onClose()
                            }
                        } label: {
                            Label(
                                note.status == .open ? "Resolve" : "Reopen",
                                systemImage: note.status == .open
                                    ? "checkmark.circle"
                                    : "arrow.uturn.backward.circle"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.aw.mauve)
                    }
                    .padding(16)
                }
            }
        } else {
            // Structurally unreachable now that the sheet captures its note at
            // open time; kept as a backstop so a future regression dead-ends
            // into a recoverable state instead of an empty shell (review).
            ContentUnavailableView {
                Label("Note Removed", systemImage: "note.text")
            } description: {
                Text("This document note was removed outside this pane.")
            } actions: {
                if allowsEditing {
                    Button("Add Note") {
                        draft = ""
                        isEditing = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.aw.mauve)
                }
            }
            .frame(minHeight: 220)
        }
    }

    private func save() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let saved = note.map { onEdit($0.id, value) } ?? onAdd(value)
        if saved {
            onClose()
        }
    }
}

private struct MultilineDocumentNoteEditor: View {
    let title: String
    @Binding var draft: String
    let submitTitle: String
    let onCancel: () -> Void
    let onSubmit: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.aw.text)
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Write a note about the whole document…")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.aw.text3)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .focused($isFocused)
                    .accessibilityLabel(title)
            }
            .frame(minHeight: 160, maxHeight: 320)
            .background(Color.aw.surface.elevated, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isFocused ? Color.aw.mauve : Color.aw.border2, lineWidth: 1)
            }

            HStack {
                Text("Return inserts a new line · ⌘Return submits")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.aw.text3)
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.aw.text2)
                    .keyboardShortcut(.cancelAction)
                Button(submitTitle, action: onSubmit)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.aw.mauve)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .onAppear { isFocused = true }
    }
}
