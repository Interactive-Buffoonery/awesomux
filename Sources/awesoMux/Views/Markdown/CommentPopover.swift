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
                            // ponytail: matches ⌘Return only, not ⌘-keypad-Enter;
                            // swap the TextField for the AppKit accept-chord bridge
                            // if keypad users report it.
                            .keyboardShortcut(.return, modifiers: .command)
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
                    // Never active at the same time as the edit-mode Save
                    // button (isEditing gates them), so the chord can't clash.
                    // ponytail: matches ⌘Return only, not ⌘-keypad-Enter; swap
                    // the TextField for the AppKit accept-chord bridge if
                    // keypad users report it.
                    .keyboardShortcut(.return, modifiers: .command)
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
    @State private var isDraftFocused = false

    private var placeholder: String {
        switch intent {
        case .comment: String(localized: "Add a note…", comment: "Placeholder for a new comment annotation")
        case .replace: String(localized: "Replacement text…", comment: "Placeholder for a replacement annotation")
        case .delete: String(localized: "Why remove? (optional)", comment: "Placeholder for an optional deletion rationale")
        }
    }

    /// Delete may carry an empty rationale; comment/replace need a payload.
    private var canSave: Bool {
        intent == .delete || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
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
                SettingsSegmented<PlanAnnotationIntent>(
                    options: [
                        .init(
                            value: .comment,
                            label: String(localized: "Comment", comment: "Annotation intent option"),
                            accessibilityLabel: String(
                                localized: "Comment annotation intent",
                                comment: "Accessibility label for the comment annotation intent option"
                            )
                        ),
                        .init(
                            value: .replace,
                            label: String(localized: "Replace", comment: "Annotation intent option"),
                            accessibilityLabel: String(
                                localized: "Replace annotation intent",
                                comment: "Accessibility label for the replace annotation intent option"
                            )
                        ),
                        .init(
                            value: .delete,
                            label: String(localized: "Delete", comment: "Annotation intent option"),
                            accessibilityLabel: String(
                                localized: "Delete annotation intent",
                                comment: "Accessibility label for the delete annotation intent option"
                            )
                        ),
                    ],
                    selection: $intent,
                    expandsToFill: true
                )
                .frame(maxWidth: .infinity)
                .awAccent(.mauve)

                AnnotationNoteTextView(
                    text: $draft,
                    isFocused: $isDraftFocused,
                    placeholder: placeholder,
                    accessibilityLabel: String(
                        localized: "Annotation note",
                        comment: "Accessibility label for the new annotation note field"
                    ),
                    onSave: save
                )
                // Approximately matches TextField's four reserved 13-point lines.
                .frame(height: 76)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.aw.mauve.opacity(0.4), lineWidth: 1)
                )
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

                // Same Return contract and hint copy as DocumentNoteSheet, so
                // the two annotation composers can't teach opposite rules.
                Text(String(localized: "Return inserts a new line · ⌘Return submits", comment: "Document note editor keyboard help"))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.aw.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Button(
                        String(localized: "Cancel", comment: "Button to cancel composing an annotation"),
                        role: .cancel,
                        action: onCancel
                    )
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .disabled(submission.isInFlight)

                    Button(action: save) {
                        Text(String(localized: "Save", comment: "Button to save a new annotation"))
                            .foregroundStyle(Color.aw.status.onLoud)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.aw.mauve)
                    // No .defaultAction here: plain Return types a newline in
                    // the note field; ⌘Return (the AppKit accept-chord bridge)
                    // is the submit path, popover-wide.
                    .disabled(!canSubmit)
                }
            }
            .padding(10)
        }
        .frame(width: 300)
        // Round-2 maintainer finding: the Comment/Replace/Delete segmented
        // control read as a muted gray-purple with a stray divider instead of
        // a crisp mauve pill — it looked nothing like the same component in
        // Settings. Root cause: this view has no opaque background of its
        // own, so it inherits NSPopover's default vibrant material; the
        // segmented control's selected-fill (`accentSoft`, a 22%-opacity
        // overlay per SettingsSegmented.swift) is exactly the kind of
        // translucent content that vibrancy remaps, while Settings renders
        // the identical component against a plain opaque window and looks
        // correct. `AwModalView` (also hosted outside a normal window, see
        // its own `panelBackground` comment) solves the identical class of
        // problem the same way — give this popover its own opaque backdrop
        // instead of trusting NSPopover's default material.
        .background(Color.aw.surface.chrome)
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

// MARK: - AnnotationNoteTextView

/// The new-annotation popover's narrowly scoped multiline AppKit editor.
private struct AnnotationNoteTextView: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let accessibilityLabel: String
    let onSave: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            AnnotationNoteTextViewRepresentable(
                text: $text,
                isFocused: $isFocused,
                accessibilityLabel: accessibilityLabel,
                accessibilityHint: placeholder,
                onSave: onSave
            )

            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// NSTextView that treats the shared keyboard-accept chord (⌘Return /
/// ⌘-keypad-Enter, `AwKeyboardAcceptChord`) as "save". The chord has no entry
/// in the standard key-binding table, so it never reaches the delegate's
/// `doCommandBy insertNewline` path — it must be claimed at the
/// key-equivalent stage instead.
final class AnnotationAcceptChordTextView: NSTextView {
    var onAcceptChord: () -> Void = {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
            !event.isARepeat,
            isEditable,
            !hasMarkedText(),
            AwKeyboardAcceptChord.isKeyboardAcceptKeyDown(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags
            )
        {
            onAcceptChord()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private struct AnnotationNoteTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let accessibilityLabel: String
    // OpenCode review: the old TextField's placeholder doubled as its
    // accessibility label; this bridge's label is fixed ("Annotation note"),
    // so the intent-specific guidance ("Add a note…" vs "Replacement text…"
    // vs "Why remove? (optional)") needs to reach VoiceOver as a hint instead.
    let accessibilityHint: String
    let onSave: () -> Void
    // The ancestor VStack carries `.disabled(submission.isInFlight)`; SwiftUI's
    // native TextField picks that up for free, but an NSViewRepresentable
    // doesn't unless it reads the environment explicitly (review finding:
    // without this, the field stayed editable while Cancel/Save/segmented
    // control correctly grayed out during an in-flight save).
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused, onSave: onSave)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = AnnotationAcceptChordTextView()
        // Route through the coordinator, whose onSave updateNSView keeps
        // fresh — capturing self.onSave here would freeze the make-time copy.
        textView.onAcceptChord = { [weak coordinator = context.coordinator] in
            coordinator?.onSave()
        }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.font = .systemFont(ofSize: 13)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 5)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityHelp(accessibilityHint)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        context.coordinator.isFocused = $isFocused
        context.coordinator.onSave = onSave

        if textView.string != text {
            textView.string = text
        }
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityHelp(accessibilityHint)
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled

        if isFocused, isEnabled, textView.window?.firstResponder !== textView {
            // Cross-model review: re-check state inside the dispatched closure,
            // not just at schedule time — isFocused can change before the next
            // runloop tick (Binding reads live); isEditable reflects the AppKit
            // side's own current truth, which any intervening updateNSView call
            // already applied, so it's fresher than re-reading the environment
            // value this closure captured by copy.
            DispatchQueue.main.async { [weak textView] in
                guard let textView, self.isFocused, textView.isEditable else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>
        var onSave: () -> Void

        init(text: Binding<String>, isFocused: Binding<Bool>, onSave: @escaping () -> Void) {
            self.text = text
            self.isFocused = isFocused
            self.onSave = onSave
        }

        func textDidBeginEditing(_ notification: Notification) {
            isFocused.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isFocused.wrappedValue = false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
