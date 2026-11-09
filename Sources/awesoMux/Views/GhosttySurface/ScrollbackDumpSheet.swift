import AppKit
import AwesoMuxConfig
import DesignSystem
import SwiftUI

struct ScrollbackDumpSheet: View {
    let presentation: ScrollbackDumpPresentation
    let revision: UInt64
    let onDismiss: () -> Void

    @Environment(AppSettingsStore.self) private var appSettingsStore
    @State private var findTarget = ScrollbackDumpFindTarget()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Scrollback")
                    .awFont(AwFont.UI.title)
                    .foregroundStyle(Color.aw.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Find") { findTarget.show(for: revision) }
                    .keyboardShortcut(
                        KeyboardShortcutCatalog.resolved(KeyboardShortcutCatalog.find, keyboard: appSettingsStore.keyboard.value)
                    )
                    .disabled(presentation.copyPayload == nil)
                    .help(
                        String(
                            localized: "Find in this scrollback snapshot",
                            comment: "Help for searching only the immutable Scrollback sheet text"))
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
        .task(id: revision) {
            guard let announcement = presentation.accessibilityAnnouncement else {
                return
            }
            await Task.yield()
            guard !Task.isCancelled else {
                return
            }
            TerminalAccessibilityAnnouncer.announce(announcement)
        }
        // Escape needs its own control. Two `.keyboardShortcut` modifiers do not
        // stack on one button — the outer replaces the inner, so stacking
        // `.cancelAction` onto Done cost it `.defaultAction` and left Return
        // dead. Hosted in a background so the sheet's layout ignores it.
        .background {
            Button("Close") {
                if !findTarget.hide(for: revision) { onDismiss() }
            }
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
                Text(String(localized: "Preparing scrollback…", comment: "Loading message while Show Scrollback reads terminal history"))
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
            ScrollbackDumpTextView(text: text, revision: revision, findTarget: findTarget, onDismiss: onDismiss)
                .id(revision)

        case let .recent(text):
            VStack(alignment: .leading, spacing: 0) {
                Text(
                    String(
                        localized:
                            "Showing recent output. Older output is omitted. This snapshot does not update as the terminal changes. The first line may be incomplete.",
                        comment: "Notice above a bounded recent terminal snapshot; the notice is not part of the copied terminal text"
                    )
                )
                .awFont(AwFont.UI.body)
                .foregroundStyle(Color.aw.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                ScrollbackDumpTextView(text: text, revision: revision, findTarget: findTarget, onDismiss: onDismiss)
                    .id(revision)
            }

        case let .blocked(reason):
            blockedContent(reason: reason)

        case .failed:
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.aw.text3)
                    .accessibilityHidden(true)
                Text(String(localized: "Couldn’t Read Scrollback", comment: "Heading when Show Scrollback cannot read terminal history"))
                    .awFont(AwFont.UI.title)
                    .foregroundStyle(Color.aw.text)
                    .accessibilityAddTraits(.isHeader)
                Text(
                    String(
                        localized: "awesoMux couldn’t read this pane’s scrollback. The terminal itself is still available.",
                        comment: "Recovery explanation when Show Scrollback fails while the terminal remains usable")
                )
                .awFont(AwFont.UI.body)
                .foregroundStyle(Color.aw.text3)
                .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func blockedContent(reason: ScrollbackDumpPolicy.BlockReason) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    String(
                        localized: "Scrollback Not Opened",
                        comment: "Heading when Show Scrollback blocks a history that cannot be read safely"),
                    systemImage: "exclamationmark.triangle"
                )
                .awFont(AwFont.UI.title)
                .foregroundStyle(Color.aw.text)
                .accessibilityAddTraits(.isHeader)
                Text(blockedMessage(for: reason))
                    .awFont(AwFont.UI.body)
                    .foregroundStyle(Color.aw.text3)
                    .fixedSize(horizontal: false, vertical: true)
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
                    "This pane’s newest output could not fit within the safe read limits. Choose Done, then scroll in the terminal or choose Pane > Find in Pane to search its history.",
                comment: "Explanation when even a bounded recent terminal snapshot cannot be read safely"
            )
        case .unknownSize:
            String(
                localized:
                    "awesoMux couldn’t determine this pane’s scrollback size safely. Choose Done, then scroll in the terminal or choose Pane > Find in Pane to search its history.",
                comment: "Explanation shown when Show Scrollback cannot safely estimate terminal history size"
            )
        case .readInProgress:
            String(
                localized: "A previous scrollback read is still finishing. Choose Done, wait a moment, then try again.",
                comment: "Explanation when Show Scrollback is retried before its previous native read finishes"
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
            let failureAnnouncement = String(
                    localized: "Could not copy the scrollback.",
                comment: "VoiceOver announcement when the scrollback sheet's Copy button failed to write to the clipboard"
            )
            TerminalAccessibilityAnnouncer.announce(
                failureAnnouncement
            )
            return
        }
        let announcement = String(
                localized: "Scrollback copied.",
                comment: "VoiceOver announcement confirming the scrollback sheet's Copy button wrote to the clipboard"
        )
        TerminalAccessibilityAnnouncer.announce(announcement)
    }
}

private extension ScrollbackDumpPresentation {
    var accessibilityAnnouncement: String? {
        switch self {
        case .loading:
            nil
        case let .loaded(text) where text.isEmpty:
            String(
                localized: "No scrollback to show.",
                comment: "VoiceOver announcement when Show Scrollback finishes with no terminal history"
            )
        case .loaded:
            String(
                localized: "Scrollback is ready.",
                comment: "VoiceOver announcement when Show Scrollback finishes loading terminal history"
            )
        case .recent:
            String(
                localized: "Recent output is ready. Older output is omitted. The first line may be incomplete.",
                comment: "VoiceOver announcement when Show Scrollback finishes loading a bounded recent snapshot"
            )
        case let .blocked(reason):
            blockedMessage(for: reason)
        case .failed:
            String(
                localized: "Could not read this pane's scrollback.",
                comment: "VoiceOver announcement when Show Scrollback cannot read the terminal history"
            )
        }
    }

    private func blockedMessage(for reason: ScrollbackDumpPolicy.BlockReason) -> String {
        switch reason {
        case .tooLarge, .nativeResultTooLarge:
            String(
                localized: "Scrollback was not opened because the newest output exceeds the safe read limits.",
                comment: "VoiceOver announcement when a bounded recent snapshot cannot be read safely"
            )
        case .unknownSize:
            String(
                localized: "Scrollback was not opened because its size could not be measured.",
                comment: "VoiceOver announcement when Show Scrollback cannot estimate terminal history size"
            )
        case .readInProgress:
            String(
                localized: "Scrollback was not opened because a previous read is still finishing.",
                comment: "VoiceOver announcement when a previous Show Scrollback read is still running"
            )
        }
    }
}

private struct ScrollbackDumpTextView: NSViewRepresentable {
    let text: String
    let revision: UInt64
    let findTarget: ScrollbackDumpFindTarget
    let onDismiss: () -> Void

    func makeCoordinator() -> ScrollbackDumpFindTarget { findTarget }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: ScrollbackDumpFindTarget) {
        if coordinator.textView?.enclosingScrollView === scrollView {
            coordinator.textView = nil
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = ScrollbackSnapshotTextView()
        textView.onCancelFind = { [weak findTarget = findTarget, revision = revision, onDismiss = onDismiss] in
            if findTarget?.hide(for: revision) != true { onDismiss() }
        }
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
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
        findTarget.textView = textView
        findTarget.revision = revision
        return scrollView
    }

    // The source revision gives each immutable snapshot its own view identity.
    // Unrelated SwiftUI updates must not read or compare the multi-MB text storage.
    func updateNSView(_ scrollView: NSScrollView, context: Context) {}
}

/// Sheet-owned weak target keeps Find away from the live terminal responder.
@MainActor
private final class ScrollbackDumpFindTarget {
    weak var textView: NSTextView?
    var revision: UInt64?

    func show(for revision: UInt64) {
        guard let textView = target(for: revision),
            textView.window?.makeFirstResponder(textView) == true
        else { return }
        let sender = NSMenuItem()
        sender.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performFindPanelAction(sender)
    }

    func hide(for revision: UInt64) -> Bool {
        guard let textView = target(for: revision),
            textView.enclosingScrollView?.isFindBarVisible == true
        else { return false }
        let sender = NSMenuItem()
        sender.tag = NSTextFinder.Action.hideFindInterface.rawValue
        textView.performFindPanelAction(sender)
        textView.window?.makeFirstResponder(textView)
        return true
    }

    private func target(for revision: UInt64) -> NSTextView? {
        guard self.revision == revision,
            let textView, let window = textView.window,
            window.isKeyWindow, !textView.isHiddenOrHasHiddenAncestor,
            let contentView = window.contentView, textView.isDescendant(of: contentView)
        else { return nil }
        return textView
    }
}

/// NSTextView handles Escape before the sheet's SwiftUI cancel button.
@MainActor
private final class ScrollbackSnapshotTextView: NSTextView {
    var onCancelFind: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        if let onCancelFind { onCancelFind() } else { super.cancelOperation(sender) }
    }
}
