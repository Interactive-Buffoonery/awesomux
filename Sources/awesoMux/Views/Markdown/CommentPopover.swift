import AwesoMuxCore
import DesignSystem
import SwiftUI

// MARK: - FullCommentPopover

/// Bigfoot-style annotation view shown when the user clicks a `•••` pill on an
/// existing `<mark>` annotation. Shows the quoted text, the note, the thread,
/// and inline edit / resolve / delete / reply actions. Edit drops into a
/// SwiftUI TextField in place.
///
/// Fix 2 (INT-562): removed dead Spacers and fixed heights; the view sizes to
/// its intrinsic content height so short notes yield short popovers.
/// Fix 4 (INT-562): all chrome colors use Catppuccin Mauve via `Color.aw`.
struct FullCommentPopover: View {
    let displayNumber: Int
    let annotation: PlanAnnotation
    let quotedText: String
    /// Edit/reply report write success so this view keeps its draft and edit
    /// mode when a stale-source write fails — clearing them unconditionally
    /// discarded the user's input in exactly the case the close-on-success
    /// parent wiring was built to protect (review).
    let onEdit: (String) -> Bool
    let onDelete: () -> Void
    let onSetStatus: (PlanAnnotationStatus) -> Void
    let onReply: (String) -> Bool
    var allowsEditing: Bool = true

    @State private var isEditing = false
    @State private var draft = ""
    @State private var replyDraft = ""
    @FocusState private var isEditFieldFocused: Bool

    private var isResolved: Bool { annotation.status == .resolved }

    private var headerLabel: String {
        var parts = ["NOTE \(displayNumber)"]
        switch annotation.intent {
        case .comment: break
        case .replace: parts.append("REPLACE")
        case .delete: parts.append("DELETE")
        }
        if annotation.author != .user {
            parts.append(annotation.author.rawValue.uppercased())
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 4) {
                Text(headerLabel)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.aw.mauve)

                if isResolved {
                    Text("RESOLVED")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.aw.mauve.opacity(0.18), in: Capsule())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                if !isEditing && allowsEditing {
                    Button {
                        onSetStatus(isResolved ? .open : .resolved)
                    } label: {
                        Image(systemName: isResolved ? "arrow.uturn.backward.circle" : "checkmark.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isResolved ? "Reopen" : "Mark resolved")
                    .accessibilityLabel(isResolved ? "Reopen annotation" : "Mark annotation resolved")

                    Button {
                        draft = annotation.payload
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit annotation")

                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete annotation")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Divider()
                .padding(.horizontal, 12)

            // Quote section
            if !quotedText.isEmpty {
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(Color.aw.mauve.opacity(0.5))
                        .frame(width: 2)
                    Text(quotedText)
                        .font(.system(size: 12))
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                Divider()
                    .padding(.horizontal, 12)
            }

            // Note body / edit field
            if isEditing {
                VStack(alignment: .trailing, spacing: 6) {
                    TextField("Note…", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .lineLimit(4, reservesSpace: true)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.aw.mauve.opacity(0.4), lineWidth: 1)
                        )
                        .onSubmit(saveEdit)
                        .focused($isEditFieldFocused)
                        // Entering edit mode means "type now" — a keyboard
                        // user shouldn't have to Tab into the field.
                        .onAppear { isEditFieldFocused = true }

                    HStack(spacing: 8) {
                        Button("Cancel") {
                            isEditing = false
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))

                        Button("Save", action: saveEdit)
                            .buttonStyle(.borderedProminent)
                            .tint(Color.aw.mauve)
                            .font(.system(size: 12, weight: .medium))
                            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(10)
            } else {
                Text(annotation.payload.isEmpty ? "(no note)" : annotation.payload)
                    .font(.system(size: 13))
                    .foregroundStyle(isResolved ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            // Thread notes
            if !annotation.notes.isEmpty {
                Divider()
                    .padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(annotation.notes.enumerated()), id: \.offset) { _, note in
                        (Text(note.author == .user ? "you" : note.author.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.aw.mauve)
                        + Text("  \(note.payload)")
                            .font(.system(size: 12)))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            // Reply field. Return submits, and the visible send button gives
            // switch/voice-control users a real target (review: a submit-only
            // field has no accessible "send" action).
            if allowsEditing && !isEditing {
                Divider()
                    .padding(.horizontal, 12)
                HStack(spacing: 6) {
                    TextField("Reply…", text: $replyDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit(submitReply)
                        .accessibilityLabel("Reply to annotation")
                    Button(action: submitReply) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.aw.mauve)
                    .disabled(replyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Send reply")
                    .accessibilityLabel("Send reply")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
        }
        .frame(width: 300)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Comment \(displayNumber)\(isResolved ? ", resolved" : "")"
        )
    }

    private func saveEdit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if onEdit(trimmed) {
            isEditing = false
        }
    }

    private func submitReply() {
        let trimmed = replyDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if onReply(trimmed) {
            replyDraft = ""
        }
    }
}

// MARK: - ComposeCommentPopover

/// Popover for composing a new annotation on a selected text span.
///
/// Fix 3 (INT-562): auto-presented when the user finalises a text selection.
/// Fix 2 (INT-562): compact layout — sizes to content.
/// INT-580: a typed-intent picker chooses comment / replace / delete; the text
/// field is the note, the replacement text, or an optional delete rationale.
struct ComposeCommentPopover: View {
    let onSave: (String, PlanAnnotationIntent) -> Void
    let onCancel: () -> Void

    @State private var draft = ""
    @State private var intent: PlanAnnotationIntent = .comment
    @FocusState private var isDraftFocused: Bool

    private var placeholder: String {
        switch intent {
        case .comment: "Add a note…"
        case .replace: "Replacement text…"
        case .delete: "Why remove? (optional)"
        }
    }

    /// Delete may carry an empty rationale; comment/replace need a payload.
    private var canSave: Bool {
        intent == .delete || !draft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        guard canSave else { return }
        onSave(draft.trimmingCharacters(in: .whitespaces), intent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("NEW ANNOTATION")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.aw.mauve)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)

            Divider()
                .padding(.horizontal, 12)

            VStack(alignment: .trailing, spacing: 6) {
                Picker("Intent", selection: $intent) {
                    Text("Comment").tag(PlanAnnotationIntent.comment)
                    Text("Replace").tag(PlanAnnotationIntent.replace)
                    Text("Delete").tag(PlanAnnotationIntent.delete)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Annotation intent")

                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(4, reservesSpace: true)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.aw.mauve.opacity(0.4), lineWidth: 1)
                    )
                    .onSubmit(save)
                    .focused($isDraftFocused)
                    // Auto-presented on selection: "now type your note" is the
                    // expected next action, so put the caret there.
                    .onAppear { isDraftFocused = true }

                HStack(spacing: 8) {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))

                    Button("Save", action: save)
                        .buttonStyle(.borderedProminent)
                        .tint(Color.aw.mauve)
                        .font(.system(size: 12, weight: .medium))
                        .disabled(!canSave)
                }
            }
            .padding(10)
        }
        .frame(width: 300)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New annotation")
    }
}
