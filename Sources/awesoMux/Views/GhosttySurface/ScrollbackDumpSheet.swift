import AppKit
import DesignSystem
import SwiftUI

struct ScrollbackDumpSheet: View {
    let text: String
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
                Button("Copy", action: copy)
                    .disabled(text.isEmpty)
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
        // `fullScrollbackText()` returns "" when the native surface is gone, and
        // "" is not nil — the sheet presents regardless, so an empty dump would
        // otherwise open a 720×520 modal containing nothing at all.
        if text.isEmpty {
            Text(
                String(
                    localized: "No scrollback to show.",
                    comment: "Empty state in the Show Scrollback sheet when the pane returned no scrollback"
                )
            )
            .awFont(AwFont.UI.body)
            .foregroundStyle(Color.aw.text3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollbackDumpTextView(text: text)
        }
    }

    private func copy() {
        guard !text.isEmpty else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        TerminalAccessibilityAnnouncer.announce(
            String(
                localized: "Scrollback copied.",
                comment: "VoiceOver announcement confirming the scrollback sheet's Copy button wrote to the clipboard"
            )
        )
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
