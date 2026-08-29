import AppKit
import DesignSystem
import SwiftUI

struct ScrollbackDumpSheet: View {
    let presentation: ScrollbackDumpPresentation
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Scrollback")
                    .awFont(AwFont.UI.title)
                    .foregroundStyle(Color.aw.text)
                Spacer()
                // Disabled on an empty dump: the handler clears the pasteboard
                // before writing, so copying nothing silently destroyed whatever
                // the user had on the clipboard.
                Button(presentation.copyButtonTitle, action: copy)
                    .disabled(presentation.copyPayload == nil)
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(Color.aw.surface.chrome)

            content
                .frame(minWidth: 720, minHeight: 520)
        }
        .background(Color.aw.surface.window)
        // Escape needs its own control. Two `.keyboardShortcut` modifiers do not
        // stack on one button — the outer replaces the inner, so stacking
        // `.cancelAction` onto Done cost it `.defaultAction` and left Return
        // dead. Hosted in a background so the sheet's layout ignores it.
        .background {
            Button("Close", action: onDismiss)
                .keyboardShortcut(.cancelAction)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch presentation {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Preparing scrollback…")
                    .awFont(AwFont.UI.body)
                    .foregroundStyle(Color.aw.text3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .loaded(text) where text.isEmpty:
            Text(
                String(
                    localized: "No scrollback to show.",
                    comment: "Empty state in the Show Scrollback sheet when the pane returned no scrollback"
                )
            )
            .awFont(AwFont.UI.body)
            .foregroundStyle(Color.aw.text3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .loaded(text):
            ScrollbackDumpTextView(text: text)

        case let .blocked(preview, reason):
            blockedContent(preview: preview, reason: reason)

        case .failed:
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.aw.text3)
                    .accessibilityHidden(true)
                Text("Couldn’t Read Scrollback")
                    .awFont(AwFont.UI.title)
                    .foregroundStyle(Color.aw.text)
                Text("awesoMux couldn’t read this pane’s scrollback. The terminal itself is still available.")
                    .awFont(AwFont.UI.body)
                    .foregroundStyle(Color.aw.text3)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func blockedContent(
        preview: String?,
        reason: ScrollbackDumpPolicy.BlockReason
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Scrollback Not Opened", systemImage: "exclamationmark.triangle")
                    .awFont(AwFont.UI.title)
                    .foregroundStyle(Color.aw.text)
                Text(blockedMessage(for: reason))
                    .awFont(AwFont.UI.body)
                    .foregroundStyle(Color.aw.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let preview, !preview.isEmpty {
                Text("Visible pane only")
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text3)
                ScrollbackDumpTextView(text: preview)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func blockedMessage(for reason: ScrollbackDumpPolicy.BlockReason) -> String {
        switch reason {
        case .tooLarge, .nativeResultTooLarge:
            String(
                localized:
                    "This pane’s scrollback is too large to open safely. Scroll in the terminal or use Find (⌘F) to search its history.",
                comment: "Explanation shown when Show Scrollback blocks a large terminal history"
            )
        case .unknownSize:
            String(
                localized:
                    "awesoMux couldn’t determine this pane’s scrollback size safely. Scroll in the terminal or use Find (⌘F) to search its history.",
                comment: "Explanation shown when Show Scrollback cannot safely estimate terminal history size"
            )
        case .growing:
            String(
                localized:
                    "This pane is still producing output, so its scrollback can’t be opened safely yet. Wait for the output to stop, then try again.",
                comment: "Explanation shown when Show Scrollback blocks a terminal that is actively producing output"
            )
        }
    }

    private func copy() {
        guard let text = presentation.copyPayload else {
            return
        }
        // `clearContents()` is required before a write and empties the clipboard
        // whether or not the write then succeeds, so a failure has already cost
        // the user whatever was there. Say so rather than claim a copy.
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            let failureAnnouncement =
                switch presentation {
                case .blocked:
                    String(
                        localized: "Could not copy the visible pane text.",
                        comment: "VoiceOver announcement when copying the blocked scrollback sheet's visible-pane preview fails"
                    )
                case .loading, .loaded, .failed:
                String(
                    localized: "Could not copy the scrollback.",
                        comment: "VoiceOver announcement when the scrollback sheet's Copy button failed to write to the clipboard"
                )
                }
            TerminalAccessibilityAnnouncer.announce(
                failureAnnouncement
            )
            return
        }
        let announcement =
            switch presentation {
            case .blocked:
                String(
                    localized: "Visible pane text copied.",
                    comment: "VoiceOver announcement confirming the blocked scrollback sheet copied its visible-pane preview"
                )
            case .loading, .loaded, .failed:
            String(
                localized: "Scrollback copied.",
                comment: "VoiceOver announcement confirming the scrollback sheet's Copy button wrote to the clipboard"
            )
            }
        TerminalAccessibilityAnnouncer.announce(announcement)
    }
}

private struct ScrollbackDumpTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else {
            return
        }
        textView.string = text
    }
}
