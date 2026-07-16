import AppKit
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
    let onEdit: (String) async -> AnnotationSaveOutcome
    let onDelete: () async -> AnnotationSaveOutcome
    let onSetStatus: (PlanAnnotationStatus) async -> AnnotationSaveOutcome
    let onReply: (String) async -> AnnotationSaveOutcome
    var allowsEditing: Bool = true
    var onSubmissionChanged: (Bool) -> Void = { _ in }

    @State private var isEditing = false
    @State private var draft = ""
    @State private var replyDraft = ""
    @State private var submission = AnnotationSubmissionGate()
    @State private var recovery: AnnotationSaveOutcome?
    @State private var recoveryDraft: String?
    @State private var presentationID: UUID?
    @FocusState private var isEditFieldFocused: Bool

    private var isResolved: Bool { annotation.status == .resolved }

    private var canSubmit: Bool {
        AnnotationSaveRecovery.canSubmitExistingAnnotation(
            isSubmitting: submission.isInFlight,
            outcome: recovery
        )
    }

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
                        submit {
                            await onSetStatus(isResolved ? .open : .resolved)
                        }
                    } label: {
                        Image(systemName: isResolved ? "arrow.uturn.backward.circle" : "checkmark.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .disabled(!canSubmit)
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
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Edit annotation")

                    Button(role: .destructive) {
                        submit(operation: onDelete)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .disabled(!canSubmit)
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
                        .disabled(submission.isInFlight)

                        Button("Save", action: saveEdit)
                            .buttonStyle(.borderedProminent)
                            .tint(Color.aw.mauve)
                            .font(.system(size: 12, weight: .medium))
                            .disabled(
                                !canSubmit
                                    || draft.trimmingCharacters(in: .whitespaces).isEmpty
                            )
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
                    TextField(String(localized: "Reply…", comment: "Placeholder for the annotation reply field"), text: $replyDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit(submitReply)
                        .accessibilityLabel(
                            String(localized: "Reply to annotation", comment: "Accessibility label for the annotation reply field"))
                    Button(action: submitReply) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .foregroundStyle(Color.aw.mauve)
                    .disabled(
                        !canSubmit
                            || replyDraft.trimmingCharacters(in: .whitespaces).isEmpty
                    )
                    .help(String(localized: "Send reply", comment: "Help text for the annotation reply button"))
                    .accessibilityLabel(String(localized: "Send reply", comment: "Accessibility label for the annotation reply button"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }

            if let recovery, recovery != .saved {
                recoveryView(recovery)
            }
        }
        .frame(width: 300)
        .disabled(submission.isInFlight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            String(
                localized:
                    "Comment \(displayNumber)\(isResolved ? String(localized: ", resolved", comment: "Resolved state suffix in an annotation accessibility label") : "")",
                comment: "Accessibility label for a numbered annotation")
        )
        .onAppear { presentationID = UUID() }
        .onDisappear { presentationID = nil }
    }

    private func saveEdit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        submit(
            draftToRecover: draft,
            operation: {
                await onEdit(trimmed)
            },
            onSaved: {
                isEditing = false
            })
    }

    private func submitReply() {
        let trimmed = replyDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        submit(
            draftToRecover: replyDraft,
            operation: {
                await onReply(trimmed)
            },
            onSaved: {
                replyDraft = ""
            })
    }

    private func submit(
        draftToRecover: String? = nil,
        operation: @escaping () async -> AnnotationSaveOutcome,
        onSaved: @escaping () -> Void = {}
    ) {
        guard canSubmit, submission.begin() else { return }
        let activePresentation = presentationID
        onSubmissionChanged(true)
        Task {
            let outcome = await operation()
            guard let activePresentation, presentationID == activePresentation else { return }
            submission.finish()
            onSubmissionChanged(false)
            recovery = outcome == .saved ? nil : outcome
            recoveryDraft = outcome == .copyOnly ? draftToRecover : nil
            if outcome == .saved {
                onSaved()
            }
            AnnotationSaveRecovery.announce(
                outcome,
                hasRecoverableDraft: draftToRecover != nil
            )
        }
    }

    @ViewBuilder
    private func recoveryView(_ outcome: AnnotationSaveOutcome) -> some View {
        Divider().padding(.horizontal, 12)
        VStack(alignment: .leading, spacing: 6) {
            Text(recoveryMessage(outcome))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if outcome == .copyOnly, let recoveryDraft {
                Button(String(localized: "Copy Draft", comment: "Button to copy an annotation draft after a save conflict")) {
                    AnnotationSaveRecovery.copyDraft(recoveryDraft)
                }
                .buttonStyle(.bordered)
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func recoveryMessage(_ outcome: AnnotationSaveOutcome) -> String {
        switch outcome {
        case .reloadAndRetry:
            String(
                localized: "The document changed and has reloaded. Save again to retry.",
                comment: "Annotation save recovery message after reloading a changed document")
        case .copyOnly:
            if recoveryDraft == nil {
                String(
                    localized: "The annotation changed or was removed.",
                    comment: "Annotation save recovery message when no draft can be recovered")
            } else {
                String(
                    localized: "The annotation changed or was removed. Copy your draft before closing.",
                    comment: "Annotation save recovery message when a draft can be copied")
            }
        case .copyAndReselect:
            String(
                localized: "The selection is stale. Copy your draft and select the text again.",
                comment: "Annotation save recovery message for a stale selection")
        case .failed:
            String(localized: "The draft was not saved.", comment: "Annotation save failure message")
        case .saved:
            ""
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
    let onSave: (String, PlanAnnotationIntent) async -> AnnotationSaveOutcome
    let onCancel: () -> Void
    var onSubmissionChanged: (Bool) -> Void = { _ in }

    @State private var draft = ""
    @State private var intent: PlanAnnotationIntent = .comment
    @State private var submission = AnnotationSubmissionGate()
    @State private var recovery: AnnotationSaveOutcome?
    @State private var presentationID: UUID?
    @FocusState private var isDraftFocused: Bool

    private var placeholder: String {
        switch intent {
        case .comment: String(localized: "Add a note…", comment: "Placeholder for a new comment annotation")
        case .replace: String(localized: "Replacement text…", comment: "Placeholder for a replacement annotation")
        case .delete: String(localized: "Why remove? (optional)", comment: "Placeholder for an optional deletion rationale")
        }
    }

    /// Delete may carry an empty rationale; comment/replace need a payload.
    private var canSave: Bool {
        intent == .delete || !draft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canSubmit: Bool {
        AnnotationSaveRecovery.canSubmitNewAnnotation(
            hasValidDraft: canSave,
            isSubmitting: submission.isInFlight,
            outcome: recovery
        )
    }

    private func save() {
        guard canSubmit, submission.begin() else { return }
        let activePresentation = presentationID
        onSubmissionChanged(true)
        let value = draft.trimmingCharacters(in: .whitespaces)
        Task {
            let outcome = await onSave(value, intent)
            guard let activePresentation, presentationID == activePresentation else { return }
            submission.finish()
            onSubmissionChanged(false)
            recovery = outcome == .saved ? nil : outcome
            AnnotationSaveRecovery.announce(outcome)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "NEW ANNOTATION", comment: "Heading for the new annotation popover"))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.aw.mauve)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)

            Divider()
                .padding(.horizontal, 12)

            VStack(alignment: .trailing, spacing: 6) {
                Picker(String(localized: "Intent", comment: "Label for the annotation intent picker"), selection: $intent) {
                    Text(String(localized: "Comment", comment: "Annotation intent option")).tag(PlanAnnotationIntent.comment)
                    Text(String(localized: "Replace", comment: "Annotation intent option")).tag(PlanAnnotationIntent.replace)
                    Text(String(localized: "Delete", comment: "Annotation intent option")).tag(PlanAnnotationIntent.delete)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(String(localized: "Annotation intent", comment: "Accessibility label for the annotation intent picker"))

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

                if let recovery, recovery != .saved {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(recoveryMessage(recovery))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if recovery == .copyAndReselect {
                            Button(String(localized: "Copy Draft", comment: "Button to copy a new annotation draft after a save conflict"))
                            {
                                AnnotationSaveRecovery.copyDraft(draft)
                            }
                            .buttonStyle(.bordered)
                            .font(.system(size: 11))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    Button(String(localized: "Cancel", comment: "Button to cancel composing an annotation"), action: onCancel)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                        .disabled(submission.isInFlight)

                    Button(String(localized: "Save", comment: "Button to save a new annotation"), action: save)
                        .buttonStyle(.borderedProminent)
                        .tint(Color.aw.mauve)
                        .font(.system(size: 12, weight: .medium))
                        .disabled(
                            !canSubmit
                        )
                }
            }
            .padding(10)
        }
        .frame(width: 300)
        .disabled(submission.isInFlight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "New annotation", comment: "Accessibility label for the new annotation popover"))
        .onAppear { presentationID = UUID() }
        .onDisappear { presentationID = nil }
    }

    private func recoveryMessage(_ outcome: AnnotationSaveOutcome) -> String {
        switch outcome {
        case .copyAndReselect:
            String(
                localized: "The document changed, so this selection is no longer safe. Copy the draft and select the text again.",
                comment: "New annotation recovery message for a stale selection")
        case .reloadAndRetry:
            String(
                localized: "The document changed and has reloaded. Save again to retry.",
                comment: "New annotation recovery message after reloading a changed document")
        case .copyOnly:
            String(localized: "Copy the draft before closing.", comment: "New annotation recovery message when only copying is safe")
        case .failed:
            String(localized: "The draft was not saved.", comment: "New annotation save failure message")
        case .saved:
            ""
        }
    }
}
