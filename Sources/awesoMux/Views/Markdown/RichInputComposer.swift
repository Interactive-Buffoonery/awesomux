import AppKit
import AwesoMuxCore
import DesignSystem
import SwiftUI

/// Outcome of staging composer text into a terminal pane. `.failed` keeps the
/// composer open with the draft intact so a send that lands on a dead surface
/// isn't silent data loss.
enum RichInputSendResult: Equatable {
    case sent
    case failed(String)
}

/// A multiline prompt composer (INT-754 v1). Evolves the document pane's
/// one-shot "send to agent" nudge into an editable box: the user can revise or
/// extend the seeded text before it is staged into the associated terminal.
///
/// Enter stages the text (chat-app convention); Shift/Option-Enter inserts a
/// newline. Staging reuses the existing send path, which pastes the block into
/// the prompt without submitting — the user still presses Return in the
/// terminal, preserving the nudge's deliberate human-in-the-loop gate.
struct RichInputComposerSheet: View {
    let title: String
    /// Stages the sanitized draft; returns `.sent` on success or `.failed`
    /// (with a reason) to keep the composer open.
    let onSend: (String) -> RichInputSendResult
    let onClose: () -> Void

    @State private var draft: String
    @State private var editorHeight: CGFloat = RichInputComposerSheet.minEditorHeight
    @State private var isEditorFocused = false
    @State private var failureMessage: String?
    @State private var isSending = false

    private static let minEditorHeight: CGFloat = 96
    private static let maxEditorHeight: CGFloat = 260

    init(
        seed: String,
        title: String,
        onSend: @escaping (String) -> RichInputSendResult,
        onClose: @escaping () -> Void
    ) {
        self.title = title
        self.onSend = onSend
        self.onClose = onClose
        _draft = State(initialValue: seed)
    }

    private var canSend: Bool {
        // Gate on the sanitized payload, not a raw whitespace trim, so a draft of
        // only control/formatting characters can't enable Send and then fail.
        !RichInputStaging.stagedPayload(draft).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.aw.border2)
            editor
                .padding(16)
            if let failureMessage {
                Text(failureMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.aw.peach)
                    .padding(.horizontal, 16)
            }
            footer
        }
        .frame(width: 620)
        .background(Color.aw.surface.window)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.aw.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.aw.text2)
            .help(Text("Close composer"))
            .accessibilityLabel(Text("Close composer"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if draft.isEmpty {
                Text("Write a prompt to send to this document's terminal…")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.aw.text2)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            RichInputTextView(
                text: $draft,
                measuredHeight: $editorHeight,
                isFocused: $isEditorFocused,
                minHeight: Self.minEditorHeight,
                maxHeight: Self.maxEditorHeight,
                onSend: send,
                onCancel: onClose
            )
            .frame(height: min(max(editorHeight, Self.minEditorHeight), Self.maxEditorHeight))
        }
        .background(Color.aw.surface.elevated, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(isEditorFocused ? Color.aw.mauve : Color.aw.border2, lineWidth: 1)
        }
        // A failure names the draft that was rejected; once the user edits, it's
        // stale — clear it so it doesn't imply the new draft is still rejected.
        .onChange(of: draft) { failureMessage = nil }
    }

    private var footer: some View {
        HStack {
            Text("Return pastes into the terminal · ⇧Return or ⌥Return for a new line")
                .font(.system(size: 11))
                .foregroundStyle(Color.aw.text2)
            Spacer()
            Button(String(localized: "Cancel", comment: "Button to dismiss the rich-input composer"), action: onClose)
                .buttonStyle(.plain)
                .foregroundStyle(Color.aw.text2)
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Send", comment: "Button to stage the composed prompt into the terminal"), action: send)
                .buttonStyle(.borderedProminent)
                .tint(Color.aw.mauve)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
        }
        .padding(16)
    }

    private func send() {
        // Reentrancy guard: a second Return during the dismiss animation would
        // otherwise stage the payload twice.
        guard canSend, !isSending else { return }
        isSending = true
        switch onSend(draft) {
        case .sent:
            onClose()
        case .failed(let reason):
            failureMessage = reason
            isSending = false
        }
    }
}

// MARK: - Editable NSTextView bridge

/// Editable NSTextView wrapper that stages on plain Return and grows with its
/// content up to a cap. AppKit rather than SwiftUI's `TextEditor` because a
/// focused `TextEditor` consumes plain Return as a newline before SwiftUI key
/// handling sees it — intercepting it here via `doCommandBy` is the reliable way
/// to get Enter-to-send while Shift/Option-Enter still inserts a newline.
private struct RichInputTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    @Binding var isFocused: Bool
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let onSend: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 5, height: 8)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.setAccessibilityLabel(String(localized: "Prompt", comment: "Accessibility label for the rich-input composer text editor"))
        // The Return-sends convention lives in a visual footer; surface it to
        // VoiceOver so a screen-reader user doesn't stage into a live PTY by
        // surprise.
        textView.setAccessibilityHelp(
            String(
                localized: "Return pastes into the terminal. Shift-Return or Option-Return inserts a new line.",
                comment: "Accessibility help describing the composer's Return-key behavior"
            )
        )

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // First responder can only be set once the view is in a window.
        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
            context.coordinator.recomputeHeight()
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Refresh the coordinator's captured view so its onSend/onCancel closures
        // and bindings don't go stale across SwiftUI struct recreations.
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichInputTextView
        weak var textView: NSTextView?

        init(_ parent: RichInputTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            recomputeHeight()
        }

        func textDidBeginEditing(_ notification: Notification) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textDidEndEditing(_ notification: Notification) {
            if parent.isFocused { parent.isFocused = false }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                // A physical Return keeps its NSEvent here; AX/scripted
                // insertNewline: has no currentEvent, so an empty flag set falls
                // through to the send path — the intended default for a bare
                // "commit this field" instruction.
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                let outcome = RichInputStaging.returnKeyOutcome(
                    shift: flags.contains(.shift),
                    option: flags.contains(.option)
                )
                switch outcome {
                case .send:
                    parent.onSend()
                    return true
                case .insertNewline:
                    textView.insertNewlineIgnoringFieldEditor(self)
                    return true
                }
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }

        func recomputeHeight() {
            guard let textView,
                let layoutManager = textView.layoutManager,
                let container = textView.textContainer
            else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let height = used + textView.textContainerInset.height * 2
            let clamped = min(max(height, parent.minHeight), parent.maxHeight)
            // Event-driven (textDidChange / async post-layout), never during a
            // SwiftUI update pass, so writing the binding here is safe.
            if abs(parent.measuredHeight - clamped) > 0.5 {
                parent.measuredHeight = clamped
            }
        }
    }
}
