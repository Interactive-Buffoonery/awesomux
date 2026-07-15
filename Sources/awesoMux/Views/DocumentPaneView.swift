import AppKit
import AwesoMuxCore
import DesignSystem
import SwiftUI

// MARK: - DocumentPaneSendBar

/// A bottom action bar hosting the prominent "Send to Agent" button. Lives below
/// the rendered document (rather than in the title bar) so the primary action — push
/// your review comments to the agent — reads as a real call-to-action instead of a
/// glyph that's easily lost in the chrome.
struct DocumentPaneSendBar: View {
    let pane: DocumentPane
    let session: TerminalSession
    let runtime: GhosttyRuntime
    /// Set true by the parent on the `> 0 -> 0` resolve transition (INT-683). The
    /// notice clears on state change — a new comment, a file switch, or the pane
    /// closing — not on a timer, so it tracks the actual review state rather than
    /// vanishing on a clock (HIG: prefer clearing status on cause, not timeout).
    @Binding var showAllResolvedNotice: Bool

    /// Whether the last nudge attempt found no live surface — shown briefly so the
    /// user knows the action failed rather than silently no-oping.
    @State private var nudgeFailed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether `TerminalPane.agentKind` is a trustworthy "which agent is live in this
    /// pane right now" signal. It is NOT yet: the runtime only resets `agentKind` to
    /// `.shell` on a clean `sessionEnd` event, so a pane that once ran Claude reads
    /// `.claudeCode` forever after even while sitting at a bare shell prompt. Reliable
    /// per-pane agent detection is available; flip this to `true`
    /// then and the button names the agent automatically. Until then the label stays
    /// honest-but-generic ("Send to Agent") rather than mislabeling shells.
    private static let agentDetectionTrustworthy = false

    private var nudgeResolution: DocumentNudgeTargetResolution {
        session.layout.documentNudgeTarget(for: pane.id)
    }

    /// The agent running in the terminal the nudge targets. Drives the button label
    /// once `agentDetectionTrustworthy` is true. Uses the same deterministic
    /// target resolver as the send action so nil associations may recover to a
    /// direct sibling, while stale explicit associations still fail closed.
    private var targetAgentKind: AgentKind {
        guard case .available(let target) = nudgeResolution else { return .shell }
        return target.agentKind
    }

    private var sendUnavailableDescription: String? {
        guard case .unavailable(let reason) = nudgeResolution else { return nil }
        switch reason {
        case .readOnlyRemoteSnapshot:
            return String(
                localized: "Remote Markdown snapshots are read-only and cannot be sent",
                comment: "Unavailable reason for sending a read-only remote Markdown snapshot to an agent"
            )
        case .terminalUnavailable:
            return String(
                localized: "This document's terminal isn't available",
                comment: "Unavailable reason for sending a document when its associated terminal is gone"
            )
        case .requiresLocalTerminal:
            return String(
                localized: "Local document paths can only be sent to a local terminal",
                comment: "Unavailable reason for sending a Mac-local document path to a declared SSH terminal"
            )
        }
    }

    /// "Send to Claude" / "Send to Codex" / … when the associated terminal's agent
    /// is known and detection is trustworthy; generic "Send to Agent" otherwise.
    private var sendButtonTitle: String {
        guard Self.agentDetectionTrustworthy else { return "Send to Agent" }
        let kind = targetAgentKind
        return kind == .shell ? "Send to Agent" : "Send to \(kind.shortName)"
    }

    var body: some View {
        HStack(spacing: 0) {
            if let origin = pane.remoteSnapshotOrigin {
                Label("Read-only snapshot from \(origin)", systemImage: "lock")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.aw.text2)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .accessibilityLabel(Text("Read-only remote Markdown snapshot from \(origin)"))
            } else {
                Spacer(minLength: 0)
                SendToAgentButton(
                    title: sendButtonTitle,
                    failed: nudgeFailed,
                    unavailableDescription: sendUnavailableDescription,
                    action: performNudge
                )
                .frame(height: 28)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(DocumentPaneChrome.barBackground(edge: .top))
        // The resolved notice floats as a small toast centered above the
        // full-width Send button rather than sharing its row — the button spans
        // the bar, so there's no in-line room for it (INT-683). The overlay
        // draws upward out of the bar's top edge over the pane, and never
        // reflows the button.
        .overlay(alignment: .top) {
            if showAllResolvedNotice {
                AllCommentsResolvedNotice {
                    showAllResolvedNotice = false
                }
                .offset(y: -30)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showAllResolvedNotice)
        .accessibilityElement(children: .contain)
        // Structured reset: when nudgeFailed flips true, sleep 2s then clear it.
        .task(id: nudgeFailed) {
            guard nudgeFailed else { return }
            try? await Task.sleep(for: .seconds(2))
            nudgeFailed = false
        }
    }

    // MARK: - Nudge action

    private func performNudge() {
        // Route through the tab's deterministic send target. This is not an
        // activePaneID fallback: live stored associations win, nil associations
        // may recover to the document group's direct split sibling, and stale
        // explicit associations fail closed rather than guessing.
        guard case .available(let targetPane) = session.layout.documentNudgeTarget(for: pane.id)
        else {
            reportNudgeUnavailable()
            return
        }
        let targetID = targetPane.id
        // Make the path relative to the TARGET terminal's cwd, not the active pane's —
        // in a nested split those differ, and the nudge lands in the target, so a path
        // relative to a different pane would be wrong for the agent (Codex review).
        let displayPath = Self.resolveDisplayPath(
            for: pane.fileURL,
            relativeTo: targetPane.workingDirectory
        )
        let text = NudgeComposer.text(displayPath: displayPath)
        // Drive the flag off the result both ways so a success after a prior failure
        // clears the Peach state immediately (re-keying the reset task), rather than
        // leaving it stale until the original 2s timer fires.
        if runtime.sendText(text, toPane: targetID) {
            nudgeFailed = false
            TerminalAccessibilityAnnouncer.announce(
                String(
                    localized: "Sent comments to this document's terminal",
                    comment: "VoiceOver announcement when sending document comments to the associated terminal succeeds"
                )
            )
        } else {
            reportNudgeFailure()
        }
    }

    private func reportNudgeUnavailable() {
        nudgeFailed = true
        TerminalAccessibilityAnnouncer.announce(
            sendUnavailableDescription
                ?? String(
                    localized: "Couldn't send — this document's terminal isn't available",
                    comment: "VoiceOver announcement when a document has no eligible send target"
                )
        )
    }

    private func reportNudgeFailure() {
        nudgeFailed = true
        // The visual failure state is a hue + glyph swap that reverts after 2s;
        // a VoiceOver user who pressed the button needs to hear the outcome now.
        TerminalAccessibilityAnnouncer.announce(
            String(
                localized: "Couldn't send — this document's terminal isn't running",
                comment: "VoiceOver announcement when sending to a document's terminal fails"
            )
        )
    }

    /// Resolves the display path for the nudge text, relative to `cwd`.
    nonisolated static func resolveDisplayPath(
        for fileURL: URL,
        relativeTo cwd: String
    ) -> String {
        let raw = rawDisplayPath(for: fileURL, relativeTo: cwd)
        // Filenames are untrusted (a hostile repo can ship `evil\n.md`). The nudge is
        // typed into the live PTY with no trailing newline so the user is the trigger
        // — but an embedded newline/CR/ESC in the path would auto-submit a partial
        // line, bypassing that gate. Strip control characters before the string ever
        // reaches the terminal; U+FFFD keeps the path legible.
        return String(
            raw.unicodeScalars.map {
                CharacterSet.controlCharacters.contains($0) ? "\u{FFFD}" : Character($0)
            })
    }

    private nonisolated static func rawDisplayPath(
        for fileURL: URL,
        relativeTo cwd: String
    ) -> String {
        let filePath = fileURL.path
        guard !cwd.isEmpty, !filePath.isEmpty else {
            return fileURL.lastPathComponent
        }
        let cwdWithSlash = cwd.hasSuffix("/") ? cwd : cwd + "/"
        guard filePath.hasPrefix(cwdWithSlash) else {
            return fileURL.lastPathComponent
        }
        let relative = String(filePath.dropFirst(cwdWithSlash.count))
        return relative.isEmpty ? fileURL.lastPathComponent : relative
    }
}

// MARK: - AllCommentsResolvedNotice

/// A quiet floating confirmation shown above the send bar when a document's last
/// comment is resolved (INT-683). Deliberately understated — a checkmark and a
/// short phrase in the secondary text color, not an accent-tinted banner: this
/// is a calm "you're done here", not a celebration or a call to action. Sized to
/// a fixed 24pt toast so it reads as a distinct transient object floating over
/// the pane, not chrome that reflows the button row.
private struct AllCommentsResolvedNotice: View {
    private static let label = String(
        localized: "All comments resolved",
        comment: "Quiet floating confirmation above the document send bar when the last comment is resolved"
    )
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(Color.aw.text2)
                    .accessibilityHidden(true)
                Text(Self.label)
                    .font(AwFont.mono(.meta))
                    .foregroundStyle(Color.aw.text2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.aw.surface.chrome2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.aw.border2, lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.35), radius: 9, y: 6)
        .accessibilityLabel(Text(Self.label))
        .accessibilityHint("Dismisses this message")
    }
}

// MARK: - DocumentPaneChrome

/// Shared chrome styling for the document pane's title bar and send bar so both
/// read as the same surface with a single hairline separating them from the body.
enum DocumentPaneChrome {
    static var barBackground: some View {
        barBackground(edge: .bottom)
    }

    static func barBackground(edge: VerticalEdge) -> some View {
        Color.aw.surface.chrome
            .overlay(alignment: edge == .bottom ? .bottom : .top) {
                Rectangle()
                    .fill(Color.aw.border2)
                    .frame(height: 0.5)
            }
    }
}

// MARK: - SendToAgentButton

/// A first-responder-safe, prominent "Send to {Agent}" call-to-action for the
/// document pane's bottom bar. Uses the same `NSButton` + `refusesFirstResponder =
/// true` pattern as `PaneCloseButton` so clicking it cannot steal focus from the
/// sibling terminal surface (the split-collapse blank-surface bug, INT-562 PR1) — a
/// SwiftUI `Button` would, which is why this stays AppKit.
///
/// Styling — an outline ("ghost") button: accent border + accent text/glyph over a
/// faint accent-tinted fill, matching the comment pills. White text on the bright
/// accent fill failed WCAG contrast badly (white on Mocha Mauve #cba6f7 ≈ 1.9:1);
/// accent-on-dark clears it comfortably (~8:1) and reads the same in both themes.
///
/// Two AppKit-specific choices:
///   • The fill/border are painted on the button's own layer, NOT via `bezelColor`
///     on a system-bordered button. A bordered button renders an "inactive"
///     appearance when its window isn't key, so the CTA would visibly dim whenever
///     awesoMux lost focus — wrong for a primary action. Layer colors are constant.
///   • The paperplane is an inline attachment inside the title rather than the
///     button's `image` with `.imageLeading`. On a full-width button, `.imageLeading`
///     pins the glyph to the far edge while the title centers, drifting them apart;
///     folding the glyph into the attributed title centers icon+text as one unit.
private struct SendToAgentButton: NSViewRepresentable {
    let title: String
    let failed: Bool
    let unavailableDescription: String?
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .noImage
        button.refusesFirstResponder = true
        button.setButtonType(.momentaryChange)
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.borderWidth = 1
        // masksToBounds so the corner radius actually clips the border + fill.
        button.layer?.masksToBounds = true
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
        let isEnabled = unavailableDescription == nil
        nsView.isEnabled = isEnabled
        let showsFailure = failed && isEnabled
        let accent = NSColor(isEnabled ? (showsFailure ? Color.aw.peach : Color.aw.mauve) : Color.aw.text2)
        nsView.layer?.backgroundColor = accent.withAlphaComponent(0.15).cgColor
        nsView.layer?.borderColor = accent.cgColor
        // The failed state also swaps the glyph (paperplane → warning triangle):
        // the hue shift alone is a color-only signal that colorblind users can't
        // perceive (WCAG 1.4.1), and this button can't be keyboard-focused for
        // the tooltip.
        nsView.attributedTitle = Self.makeTitle(title, color: accent, failed: showsFailure)
        // Reflect the failure state in the label too — color + tooltip alone aren't
        // conveyed to VoiceOver, so failure would otherwise be invisible to it.
        nsView.setAccessibilityLabel(
            unavailableDescription.map {
                String(
                    localized: "\(title) — unavailable: \($0)",
                    comment: "Accessibility label for the document send button when its target is ineligible"
                )
            }
                ?? (failed
                    ? String(
                        localized: "\(title) — unavailable: this document's terminal isn't running",
                        comment: "Accessibility label for the send button when its terminal is gone"
                    )
                    : String(
                        localized: "\(title) — sends your review comments to this document's terminal",
                        comment: "Accessibility label for the document send button"
                    ))
        )
        nsView.toolTip =
            unavailableDescription
            ?? (failed
                ? String(
                    localized: "This document's terminal isn't available — reopen the document from a running terminal to reconnect",
                    comment: "Tooltip for the send button when its terminal is gone"
                )
                : String(
                    localized: "Send review comments to the agent in this document's terminal",
                    comment: "Tooltip for the document send button"
                ))
    }

    /// Builds a centered "✈ Send to Agent" title with the glyph as an inline,
    /// vertically-centered attachment so it sits right beside the text, both
    /// tinted `color`. The failed state swaps the paperplane for a warning
    /// triangle so failure has a shape, not just a hue.
    private static func makeTitle(_ text: String, color: NSColor, failed: Bool) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let result = NSMutableAttributedString()

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let symbolName = failed ? "exclamationmark.triangle.fill" : "paperplane.fill"
        if let glyph = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        {
            let attachment = NSTextAttachment()
            attachment.image = glyph
            // Center the glyph on the text's cap height.
            attachment.bounds = CGRect(
                x: 0,
                y: (font.capHeight - glyph.size.height) / 2,
                width: glyph.size.width,
                height: glyph.size.height
            )
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "  "))
        }

        result.append(NSAttributedString(string: text))

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        result.addAttributes(
            [.foregroundColor: color, .font: font, .paragraphStyle: paragraph],
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func fire() {
            action()
        }
    }
}

// MARK: - DocumentPaneView

/// Renders a `DocumentPane` — validates the URL, loads the markdown file, and
/// displays it using `MarkdownTextView` (Task 3+) with a `MarkdownView`
/// fallback while the `RenderedDocument` is still being built.
///
/// Load lifecycle (PR2 Task 3: read-once on appear, no live reload):
///   1. `DocumentURLValidator` checks scheme, extension, and size.
///   2. `DocumentLoader` reads the file and builds `[MarkdownBlock]`.
///   3. `AttributedMarkdownBuilder` builds the `RenderedDocument` (off-main).
///   4. `MarkdownTextView` renders the document via TextKit with custom
///      `NSAttributedString` attributes for source-offset mapping and marks.
///
/// Error states are shown inline; the pane never crashes on bad input.
struct DocumentPaneView: View {
    private struct ReloadTaskID: Equatable {
        let fileURL: URL
        let generation: Int
    }

    private struct ReloadSource {
        let generation: Int
        let source: String
    }

    /// The most recently shown comment popover, read by `DocumentComposeGuard`
    /// so agent-driven opens don't steal the selection out from under a typed
    /// draft (INT-748). Weak + single slot: only the selected tab's view is
    /// mounted and popover presentation always closes the previous one, so at
    /// most one document popover exists at a time in this single-window app.
    @MainActor weak static var activeCommentPopover: NSPopover?
    @MainActor private static var selfWriteRegistry = MarkdownSelfWriteRegistry()

    let pane: DocumentPane
    /// Reports the document's comment count on every (re)load so the send bar can
    /// surface the all-comments-resolved notice on the `> 0 -> 0` transition
    /// (INT-683). Defaulted so existing call sites and previews stay unchanged.
    var onCommentCountChanged: (Int) -> Void = { _ in }
    /// Reports every completed (re)load so the tab strip's session-memory can
    /// seed the next remount of this tab without a spinner flash (INT-748 PR2).
    var onRenderCompleted: ((DocumentTabMemory.Render) -> Void)?
    /// Opens a clicked document link as a tab inheriting THIS tab's terminal
    /// association (INT-748 PR2). When nil, document links fall back to the
    /// static `GhosttyRuntime.openDocumentHandler` path.
    var onOpenDocumentLink: ((URL) -> Void)?
    /// Reports external file edits so the parent chrome can surface a transient
    /// plan-revised indicator without tying UI state to reload logic.
    var onRevision: (LineDiffCount.ExternalEdit) -> Void = { _ in }
    /// Surfaces the coordinator's scroll-anchor capture to the group view so it
    /// can snapshot the outgoing tab's position on a tab switch (INT-748 PR2).
    var onRegisterScrollAnchorCapture: ((@escaping @MainActor () -> Int?) -> Void)?

    /// Task 6: terminal background propagated by TerminalPaneView so the highlight
    /// contrast is measured against the actual painted surface, not the app chrome.
    @Environment(\.terminalBackgroundColor) private var terminalBackgroundColor

    @State private var loadResult: DocumentLoader.LoadResult? = nil
    @State private var renderedDoc: RenderedDocument? = nil
    @State private var selectedSourceSpan: Range<Int>? = nil
    // INT-580 annotation surface state is per-pane and deliberately unpersisted.
    @State private var hideResolved = false
    /// The render the document-note sheet was opened against. Captured at open
    /// (like the popovers capture `doc`): the sheet edits against this
    /// snapshot, so an external change trips the stale-source guard instead of
    /// refreshed closures silently accepting a stale draft. Non-nil = shown.
    @State private var documentNoteSheetDoc: RenderedDocument? = nil
    @State private var lastSelfWrittenSource: String? = nil
    @State private var reloadGeneration: Int = 0
    @State private var reloadSource: ReloadSource? = nil

    // Bigfoot: driven by NSPopover directly so we can anchor to a pill rect.
    @State private var nsPopover: NSPopover? = nil
    /// NSTextView reference surfaced from MarkdownTextView for popover anchoring.
    @State private var markdownNSTextView: NSTextView? = nil

    /// Task 7: live filesystem watch + source-anchored reload.
    @State private var watcher: DocumentFileWatcher? = nil
    @State private var watcherReloadTask: Task<Void, Never>? = nil
    @State private var watcherReloadGeneration = 0
    // Written during MarkdownTextView's update pass — safe ONLY while no
    // `body` ever reads it; keep reads inside event closures.
    @State private var scrollAnchorCapture: (@MainActor () -> Int?)? = nil
    @State private var pendingScrollAnchor: Int? = nil

    /// `cachedRender` seeds `loadResult`/`renderedDoc` so a tab the user
    /// switches back to shows its content immediately instead of a spinner —
    /// the load task still re-reads the file (the watcher was off while the tab
    /// was hidden) and swaps in any changes. `initialScrollAnchor` seeds
    /// `pendingScrollAnchor` so the first render restores the tab's last scroll
    /// position; it's a `State` seed (not a fallback read on every pass) so the
    /// reset paths that clear the pending anchor stay authoritative.
    init(
        pane: DocumentPane,
        cachedRender: DocumentTabMemory.Render? = nil,
        initialScrollAnchor: Int? = nil,
        onCommentCountChanged: @escaping (Int) -> Void = { _ in },
        onRenderCompleted: ((DocumentTabMemory.Render) -> Void)? = nil,
        onOpenDocumentLink: ((URL) -> Void)? = nil,
        onRevision: @escaping (LineDiffCount.ExternalEdit) -> Void = { _ in },
        onRegisterScrollAnchorCapture: ((@escaping @MainActor () -> Int?) -> Void)? = nil
    ) {
        self.pane = pane
        self.onCommentCountChanged = onCommentCountChanged
        self.onRenderCompleted = onRenderCompleted
        self.onOpenDocumentLink = onOpenDocumentLink
        self.onRevision = onRevision
        self.onRegisterScrollAnchorCapture = onRegisterScrollAnchorCapture
        _loadResult = State(initialValue: cachedRender?.loadResult)
        _renderedDoc = State(initialValue: cachedRender?.renderedDoc)
        _pendingScrollAnchor = State(initialValue: initialScrollAnchor)
    }

    // MARK: - Derived

    private var highlightColor: NSColor {
        HighlightContrast.color(forTerminalBackground: NSColor(terminalBackgroundColor))
    }

    private var markdownTextColor: NSColor {
        MarkdownAttributedStringBuilder.textColor(forTerminalBackground: NSColor(terminalBackgroundColor))
    }

    var body: some View {
        let reloadTaskID = ReloadTaskID(
            fileURL: pane.fileURL,
            generation: reloadGeneration
        )
        let capturedReloadSource = reloadSource

        Group {
            if let result = loadResult {
                switch result {
                case let .loaded(blocks, _):
                    loadedView(blocks: blocks)

                case let .rejected(reason):
                    errorView(message: rejectionMessage(for: reason, pane: pane))

                case let .readError(message):
                    errorView(message: "Couldn't read \u{201C}\(pane.title)\u{201D}: \(message)")
                }
            } else {
                ProgressView()
                    .accessibilityLabel("Loading document")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            // No triggerReload() here: .task(id:) below already fires on
            // appearance, and a generation bump at this point cancels that
            // first task after its detached load has launched — a duplicate
            // full read+parse per mount, on what tab switching has made the
            // hot path.
            startWatcher()
        }
        .onDisappear {
            watcher?.stop()
            watcher = nil
            watcherReloadTask?.cancel()
            watcherReloadTask = nil
            watcherReloadGeneration += 1
            nsPopover?.close()
            nsPopover = nil
        }
        .task(id: reloadTaskID) {
            let source = capturedReloadSource.flatMap {
                $0.generation == reloadTaskID.generation ? $0.source : nil
            }
            if reloadSource?.generation == reloadTaskID.generation {
                reloadSource = nil
            }
            // Reuse the current document when the on-disk source is unchanged:
            // the build is a pure function of the source, so a remount seeded
            // from the tab cache (or a watcher wobble) skips the whole
            // attributed rebuild (INT-748 PR2).
            let priorDoc = renderedDoc
            let (result, doc): (DocumentLoader.LoadResult, RenderedDocument?) =
                await Task.detached(priority: .userInitiated) {
                    let result =
                        source.map { DocumentLoader.load(source: $0) }
                        ?? DocumentLoader.load(reloadTaskID.fileURL)
                    if case let .loaded(_, source) = result {
                        if let priorDoc, priorDoc.source == source {
                            return (result, priorDoc)
                        }
                        return (result, AttributedMarkdownBuilder.build(source))
                    }
                    return (result, nil)
                }.value

            guard !Task.isCancelled,
                reloadTaskID.fileURL == pane.fileURL,
                reloadTaskID.generation == reloadGeneration
            else { return }
            renderedDoc = doc
            loadResult = result
            // Report only when the content actually changed (source compare is
            // O(1) on the reuse path — same String storage). An unchanged
            // reload re-storing an identical entry would invalidate the whole
            // group view for nothing on every watcher wobble; the cache
            // already holds this content (it seeded us or stored the first
            // load). Errors (doc == nil) always report — rare, and the cache
            // should stop seeding content the disk can no longer back.
            if doc == nil || priorDoc == nil || doc?.source != priorDoc?.source {
                onRenderCompleted?(DocumentTabMemory.Render(loadResult: result, renderedDoc: doc))
            }
            // Report the comment count only on a real render — an unreadable or
            // rejected file (doc == nil) is not "all comments resolved", so we
            // leave the tracker's prior count untouched (INT-683). A visible
            // notice intentionally survives such a transient read failure too:
            // nothing is reported, so nothing retracts it.
            if let doc {
                // The document note counts toward the all-resolved notice
                // (review decision): resolving it should feel the same as
                // resolving the last inline comment. `openAnnotationCount`
                // itself stays span-only for the inline affordances.
                let openDocumentNote = doc.documentNote?.status == .open ? 1 : 0
                onCommentCountChanged(doc.openAnnotationCount + openDocumentNote)
            }
            // Do NOT clear pendingScrollAnchor here — it must survive into this very
            // render so MarkdownTextView.updateNSView receives it and restores scroll
            // on the source change. The source-change gate there means a lingering
            // anchor can't cause a spurious re-scroll on later non-reload updates, and
            // each reload caller resets it (watcher → fresh offset, reset paths → nil).
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func loadedView(blocks: [MarkdownBlock]) -> some View {
        if let doc = renderedDoc {
            let isReadOnly = pane.isReadOnlySnapshot
            let spanTouchesMark =
                selectedSourceSpan.map {
                    SelectionSourceMapping.spanTouchesExistingMark($0, in: doc)
                } ?? false
            // Hoisted: body re-evaluates per selection event, and these build
            // fresh collections (review: avoid re-deriving them ~6x per pass).
            let hiddenIDs = hideResolved ? doc.resolvedAnnotationIDs : []

            ZStack {
                VStack(spacing: 0) {
                    // Editable documents always expose the single document-note
                    // action; snapshots show it only when a note exists.
                    if !isReadOnly || doc.documentNote != nil || !doc.annotations.isEmpty {
                        documentAnnotationBar(doc: doc)
                    }
                    if doc.runs.isEmpty {
                        Text("This document is empty.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityLabel("\(pane.title) is empty")
                    } else {
                        MarkdownTextView(
                            doc: doc,
                            selectedSourceSpan: $selectedSourceSpan,
                            highlightColor: highlightColor,
                            textColor: markdownTextColor,
                            relativeLinkBaseURL: pane.fileURL.deletingLastPathComponent(),
                            allowsDocumentLinks: !isReadOnly,
                            onPillClicked: { markID, pillRect, anchorView in
                                showCommentPopover(
                                    markID: markID,
                                    pillRect: pillRect,
                                    anchorView: anchorView,
                                    doc: doc
                                )
                            },
                            onAddPillClicked: { pillRect, anchorView in
                                // Secondary affordance: still works if user clicks the add pill.
                                guard !isReadOnly, let span = selectedSourceSpan, !spanTouchesMark else { return }
                                showComposePopover(
                                    span: span,
                                    pillRect: pillRect,
                                    anchorView: anchorView,
                                    doc: doc
                                )
                            },
                            selectionTouchesMark: spanTouchesMark || isReadOnly,
                            onTextViewAvailable: { tv in markdownNSTextView = tv },
                            // Fix 3 (INT-562): auto-present compose popover when the user
                            // finalizes a selection (mouseUp with a non-empty, non-mark-touching
                            // span). Guard: don't re-present if a popover is already open (covers
                            // the "select-to-copy" case where user cancelled then re-selects —
                            // the popover already closed on Cancel/Esc/click-away, so re-selection
                            // correctly re-opens the composer with a clean state).
                            onSelectionFinalized: { span, trailingRect, tv in
                                guard !isReadOnly else { return }
                                // If a popover is already showing, don't stack another one.
                                if let existing = nsPopover, existing.isShown {
                                    return
                                }
                                showComposePopover(
                                    span: span,
                                    pillRect: trailingRect,
                                    anchorView: tv,
                                    doc: doc
                                )
                            },
                            scrollAnchorOffset: pendingScrollAnchor,
                            onRegisterScrollAnchorCapture: { capture in
                                scrollAnchorCapture = capture
                                onRegisterScrollAnchorCapture?(capture)
                            },
                            onOpenDocumentLink: onOpenDocumentLink,
                            hiddenAnnotationIDs: hiddenIDs
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contextMenu {
                            if !isReadOnly {
                                Button("Add Comment") {
                                    guard let span = selectedSourceSpan, !spanTouchesMark else { return }
                                    if let tv = markdownNSTextView {
                                        // Fix 5 (INT-562): anchor to the VISIBLE clip-view centre,
                                        // not tv.bounds.midY (which is the full document height and
                                        // will be offscreen when the document is scrolled). The clip
                                        // view's visibleRect in text-view coordinates always resolves
                                        // to somewhere the popover can appear.
                                        let visibleInTV =
                                            tv.enclosingScrollView?
                                            .contentView.bounds ?? tv.visibleRect
                                        let centRect = NSRect(
                                            x: visibleInTV.midX - 10,
                                            y: visibleInTV.midY - 10,
                                            width: 20, height: 20
                                        )
                                        showComposePopover(
                                            span: span,
                                            pillRect: centRect,
                                            anchorView: tv,
                                            doc: doc
                                        )
                                    }
                                }
                                .disabled(selectedSourceSpan == nil || spanTouchesMark)

                                Button(doc.documentNote == nil ? "Add Document Note…" : "Document Note…") {
                                    documentNoteSheetDoc = doc
                                }
                            }
                            Toggle("Hide Resolved Annotations", isOn: $hideResolved)
                        }
                    }
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { documentNoteSheetDoc != nil },
                    set: { isPresented in
                        if !isPresented {
                            documentNoteSheetDoc = nil
                        }
                    }
                ),
                onDismiss: {
                    // Same first-responder restore the popovers do: don't
                    // leave the pane unfocused when the sheet goes away.
                    // onDismiss covers every path (Esc, close button,
                    // programmatic).
                    if let tv = markdownNSTextView {
                        tv.window?.makeFirstResponder(tv)
                    }
                }
            ) {
                if let noteDoc = documentNoteSheetDoc {
                    DocumentNoteSheet(
                        note: noteDoc.documentNote,
                        onAdd: { note in
                            let saved = addDocumentNote(note, doc: noteDoc)
                            if saved {
                                TerminalAccessibilityAnnouncer.announce(
                                    String(
                                        localized: "Document note added", comment: "VoiceOver announcement after adding the document note")
                                )
                            }
                            return saved
                        },
                        onEdit: { id, newNote in
                            let saved = updateAnnotation(id: id, doc: noteDoc) { $0.payload = newNote }
                            if saved {
                                TerminalAccessibilityAnnouncer.announce(
                                    String(
                                        localized: "Document note updated",
                                        comment: "VoiceOver announcement after editing the document note")
                                )
                            }
                            return saved
                        },
                        onSetStatus: { id, status in
                            let saved = updateAnnotation(id: id, doc: noteDoc) { $0.status = status }
                            if saved {
                                TerminalAccessibilityAnnouncer.announce(
                                    status == .resolved
                                        ? String(
                                            localized: "Document note resolved",
                                            comment: "VoiceOver announcement after resolving the document note")
                                        : String(
                                            localized: "Document note reopened",
                                            comment: "VoiceOver announcement after reopening the document note")
                                )
                            }
                            return saved
                        },
                        onDelete: { id in
                            let saved = deleteAnnotation(id: id, doc: noteDoc)
                            if saved {
                                TerminalAccessibilityAnnouncer.announce(
                                    String(
                                        localized: "Document note deleted",
                                        comment: "VoiceOver announcement after deleting the document note")
                                )
                            }
                            return saved
                        },
                        onClose: {
                            documentNoteSheetDoc = nil
                        },
                        allowsEditing: !isReadOnly
                    )
                }
            }
        } else {
            // Structurally-unreachable fallback: retained as a defensive backstop.
            ScrollView(.vertical) {
                MarkdownView(blocks: blocks)
                    .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Slim chrome row above the document: the single whole-document note on
    /// the leading edge and the inline resolved filter on the trailing edge.
    private func documentAnnotationBar(doc: RenderedDocument) -> some View {
        let documentNote = doc.documentNote
        let resolvedCount = doc.resolvedAnnotationCount
        return HStack {
            if !pane.isReadOnlySnapshot || documentNote != nil {
                Button {
                    documentNoteSheetDoc = doc
                } label: {
                    Label(
                        documentNote == nil ? "Add Document Note" : "Document Note",
                        systemImage: documentNote?.status == .resolved ? "checkmark.circle" : "note.text"
                    )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(documentNote?.status == .resolved ? Color.aw.text2 : Color.aw.text)
                }
                .buttonStyle(.plain)
                .help(documentNote == nil ? "Add a document note" : "Show document note")
                .accessibilityLabel(documentNoteAccessibilityLabel(documentNote))
            }
            Spacer()
            Button {
                hideResolved.toggle()
            } label: {
                Label(
                    hideResolved ? "Show Resolved" : "Hide Resolved",
                    systemImage: hideResolved ? "eye" : "eye.slash"
                )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hideResolved ? Color.aw.mauve : Color.aw.text2)
            }
            .buttonStyle(.plain)
            .disabled(resolvedCount == 0 && !hideResolved)
            .help(resolvedAnnotationsHelpText(resolvedCount: resolvedCount))
            .accessibilityLabel("Hide resolved annotations")
            .accessibilityValue(hideResolved ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.aw.surface.chrome)
        // One announcement covers both toggle sites (bar button and context
        // menu): hiding removes pills and highlights across the whole
        // document, and VoiceOver hears nothing from the pixels changing.
        .onChange(of: hideResolved) { _, hidden in
            TerminalAccessibilityAnnouncer.announce(
                hidden
                    ? String(
                        localized: "Resolved annotations hidden",
                        comment: "VoiceOver announcement when the resolved-annotations filter turns on")
                    : String(
                        localized: "Resolved annotations shown",
                        comment: "VoiceOver announcement when the resolved-annotations filter turns off")
            )
        }
    }

    private func documentNoteAccessibilityLabel(_ note: PlanAnnotation?) -> String {
        guard let note else { return "Add document note" }
        return note.status == .open ? "Document note, open" : "Document note, resolved"
    }

    private func resolvedAnnotationsHelpText(resolvedCount: Int) -> String {
        if hideResolved { return "Show resolved annotations" }
        return resolvedCount == 0
            ? "No resolved inline annotations"
            : "Hide resolved annotations"
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Popover presentation

    private func showCommentPopover(
        markID: String,
        pillRect: NSRect,
        anchorView: NSView,
        doc: RenderedDocument
    ) {
        guard let annotation = doc.annotation(id: markID),
            let displayNumber = doc.displayNumber(for: markID)
        else { return }
        let quotedText = doc.runs.filter { $0.markID == markID }.map(\.text).joined()

        nsPopover?.close()
        nsPopover = nil

        let popover = NSPopover()
        popover.behavior = .transient
        let hosting = NSHostingController(
            rootView: FullCommentPopover(
                displayNumber: displayNumber,
                annotation: annotation,
                quotedText: quotedText,
                // Close only on SUCCESS: a stale-source failure keeps the popover
                // (and any typed draft) on screen next to the explanatory alert
                // instead of silently discarding the user's input (review). The
                // Bool result lets the popover gate its own draft/edit state the
                // same way.
                onEdit: { [weak popover] newNote in
                    let saved = updateAnnotation(id: markID, doc: doc, mutate: { $0.payload = newNote })
                    if saved {
                        popover?.close()
                        TerminalAccessibilityAnnouncer.announce(
                            String(localized: "Annotation updated", comment: "VoiceOver announcement after editing an annotation's note")
                        )
                    }
                    return saved
                },
                onDelete: { [weak popover] in
                    if deleteAnnotation(id: markID, doc: doc) {
                        popover?.close()
                        TerminalAccessibilityAnnouncer.announce(
                            String(localized: "Annotation deleted", comment: "VoiceOver announcement after deleting an annotation")
                        )
                    }
                },
                onSetStatus: { [weak popover] status in
                    if updateAnnotation(id: markID, doc: doc, mutate: { $0.status = status }) {
                        popover?.close()
                        TerminalAccessibilityAnnouncer.announce(
                            status == .resolved
                                ? String(
                                    localized: "Annotation resolved", comment: "VoiceOver announcement after marking an annotation resolved"
                                )
                                : String(localized: "Annotation reopened", comment: "VoiceOver announcement after reopening an annotation")
                        )
                    }
                },
                onReply: { [weak popover] reply in
                    let saved = replyToAnnotation(id: markID, reply: reply, doc: doc)
                    if saved {
                        popover?.close()
                        TerminalAccessibilityAnnouncer.announce(
                            annotation.status == .resolved
                                ? String(
                                    localized: "Reply added, annotation reopened",
                                    comment: "VoiceOver announcement after replying to a resolved annotation, which reopens it")
                                : String(localized: "Reply added", comment: "VoiceOver announcement after replying to an annotation")
                        )
                    }
                    return saved
                },
                allowsEditing: !pane.isReadOnlySnapshot
            ))
        // Size the popover to the SwiftUI content's intrinsic height. Without this,
        // NSPopover uses a fixed default content size, leaving a short note floating
        // in a large empty box (INT-562 live-smoke fix).
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.show(relativeTo: pillRect, of: anchorView, preferredEdge: .maxY)
        nsPopover = popover
        Self.activeCommentPopover = popover

        // Fix 3 (INT-562): restore first responder to the text view when the popover
        // closes. NSPopover with .transient behavior can steal first responder from the
        // SwiftUI TextField inside it, which would leave the adjacent ghostty terminal
        // blanked (the split-collapse first-responder bug, PR1). Explicitly returning
        // focus to the document's text view on dismiss ensures the terminal is never
        // left without a first responder.
        registerPopoverFirstResponderRestore(popover)
    }

    private func showComposePopover(
        span: Range<Int>,
        pillRect: NSRect,
        anchorView: NSView,
        doc: RenderedDocument
    ) {
        // Nested-mark guard.
        if SelectionSourceMapping.spanTouchesExistingMark(span, in: doc) {
            showNestedMarkAlert(span: span, doc: doc)
            return
        }

        nsPopover?.close()
        nsPopover = nil

        let popover = NSPopover()
        popover.behavior = .transient
        let hosting = NSHostingController(
            rootView: ComposeCommentPopover(
                onSave: { [weak popover] note, intent in
                    if insertAnnotation(span: span, intent: intent, payload: note, doc: doc) {
                        popover?.close()
                        TerminalAccessibilityAnnouncer.announce(
                            String(localized: "Annotation added", comment: "VoiceOver announcement after adding a new annotation")
                        )
                    }
                },
                onCancel: { [weak popover] in
                    popover?.close()
                }
            ))
        // sizingOptions under-measures this content (the Save/Cancel row gets cropped),
        // so measure the laid-out content explicitly and size the popover to it.
        popover.contentViewController = hosting
        hosting.view.layoutSubtreeIfNeeded()
        popover.contentSize = hosting.view.fittingSize
        popover.show(relativeTo: pillRect, of: anchorView, preferredEdge: .maxY)
        nsPopover = popover
        Self.activeCommentPopover = popover

        // Fix 3: same first-responder restore as showCommentPopover.
        registerPopoverFirstResponderRestore(popover)
    }

    /// Registers a one-shot NSPopover.willCloseNotification observer that restores
    /// first responder to the markdown text view when the popover dismisses.
    /// Without this, the SwiftUI TextField inside the popover holds first responder
    /// at close time, leaving any adjacent ghostty terminal unable to reclaim focus.
    private func registerPopoverFirstResponderRestore(_ popover: NSPopover) {
        // Stash the observer token AND the text view in one @unchecked Sendable box so
        // the @Sendable observer closure captures only the box — never a raw
        // non-Sendable NSTextView, which trips Swift 6's "capture of non-Sendable type"
        // diagnostic even though queue:.main guarantees same-thread delivery.
        let box = ObserverBox()
        box.textView = markdownNSTextView
        box.token = NotificationCenter.default.addObserver(
            forName: NSPopover.willCloseNotification,
            object: popover,
            queue: .main
        ) { [box] _ in
            // queue: .main guarantees main-thread delivery.
            MainActor.assumeIsolated {
                let tv = box.textView
                tv?.window?.makeFirstResponder(tv)
                if let t = box.token {
                    NotificationCenter.default.removeObserver(t)
                    box.token = nil
                }
            }
        }
    }

    /// Thread-safe box for the observer token + the text view so they can be captured
    /// by reference in a `@Sendable` closure without violating Sendable requirements.
    /// Access is always gated on `queue: .main`.
    private final class ObserverBox: @unchecked Sendable {
        var token: NSObjectProtocol?
        weak var textView: NSTextView?
    }

    // MARK: - Annotation writes

    @discardableResult
    private func insertAnnotation(
        span: Range<Int>,
        intent: PlanAnnotationIntent,
        payload: String,
        doc: RenderedDocument
    ) -> Bool {
        if SelectionSourceMapping.spanTouchesExistingMark(span, in: doc) {
            showNestedMarkAlert(span: span, doc: doc)
            return false
        }
        return guardedWrite(renderTimeSource: doc.source) { freshSource in
            PlanAnnotationWriter.insertingAnnotation(
                in: freshSource, span: span, author: .user, intent: intent, payload: payload
            )?.source
        }
    }

    /// One rejection message for the nested-annotation rule, shared by the
    /// compose pre-check and the insert path. When every overlapped mark is
    /// currently hidden by the resolved filter, say so — a rejection citing a
    /// mark the user cannot see reads as the tool malfunctioning (review).
    private func showNestedMarkAlert(span: Range<Int>, doc: RenderedDocument) {
        let overlapped = Set(
            doc.runs.compactMap { run -> String? in
                guard let id = run.markID, let sourceRange = run.sourceRange,
                    sourceRange.overlaps(span)
                else { return nil }
                return id
            })
        let allHidden =
            hideResolved && !overlapped.isEmpty
            && overlapped.isSubset(of: doc.resolvedAnnotationIDs)
        showAlert(
            title: "Already Annotated",
            message: allHidden
                ? "The selected text overlaps a resolved annotation that is currently hidden. Turn off Hide Resolved to see it."
                : "The selected text overlaps an existing annotation. Annotations cannot be nested — deselect the marked region and try again."
        )
    }

    /// Payload edits and status flips share one marker-local rewrite; a legacy
    /// USER COMMENT marker upgrades to the AMX form on its first write.
    @discardableResult
    private func updateAnnotation(
        id: String,
        doc: RenderedDocument,
        mutate: @escaping (inout PlanAnnotationMarker.Annotation) -> Void
    ) -> Bool {
        guardedWrite(renderTimeSource: doc.source) { freshSource in
            PlanAnnotationWriter.updatingAnnotation(id: id, in: freshSource, mutate: mutate)
        }
    }

    @discardableResult
    private func addDocumentNote(_ note: String, doc: RenderedDocument) -> Bool {
        guardedWrite(renderTimeSource: doc.source) { freshSource in
            PlanAnnotationWriter.appendingDocumentAnnotation(
                in: freshSource, author: .user, payload: note
            )?.source
        }
    }

    @discardableResult
    private func replyToAnnotation(id: String, reply: String, doc: RenderedDocument) -> Bool {
        guardedWrite(renderTimeSource: doc.source) { freshSource in
            PlanAnnotationWriter.appendingNote(to: id, in: freshSource, author: .user, payload: reply)
        }
    }

    @discardableResult
    private func deleteAnnotation(id: String, doc: RenderedDocument) -> Bool {
        guardedWrite(renderTimeSource: doc.source) { freshSource in
            PlanAnnotationWriter.removingAnnotation(id: id, in: freshSource)
        }
    }

    /// Reads the file, confirms it hasn't changed since `renderTimeSource`, then
    /// applies `writer` and writes the result back. Returns `true` on success.
    @discardableResult
    private func guardedWrite(
        renderTimeSource: String,
        writer: (String) -> String?
    ) -> Bool {
        guard !pane.isReadOnlySnapshot else {
            showAlert(title: "Read-Only Snapshot", message: "Remote Markdown snapshots cannot be edited in awesoMux yet.")
            return false
        }
        guard let onDisk = DocumentLoader.readSource(pane.fileURL) else {
            showAlert(title: "Couldn't Save", message: "The document couldn't be read from disk.")
            return false
        }
        guard onDisk == renderTimeSource else {
            showAlert(
                title: "Document Changed on Disk",
                message: "The document changed on disk. Reloading — please try again."
            )
            pendingScrollAnchor = nil
            triggerReload()
            return false
        }
        guard let newSource = writer(onDisk) else {
            showAlert(
                title: "Couldn't Save",
                message: "The annotation couldn't be saved. It may be too long, invalid, or duplicated."
            )
            return false
        }
        do {
            try newSource.write(to: pane.fileURL, atomically: true, encoding: .utf8)
            Self.selfWriteRegistry.record(fileURL: pane.fileURL, source: newSource)
            return true
        } catch {
            showAlert(title: "Couldn't Save", message: error.localizedDescription)
            return false
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Bumps the reload generation so the load `.task(id:)` re-fires. Deliberately
    /// does NOT nil `loadResult`/`renderedDoc`: keeping them set leaves the mounted
    /// `MarkdownTextView` in place so `updateNSView` swaps the new document in (and
    /// applies `scrollAnchorOffset`) instead of tearing the view down — which would
    /// flash the spinner and lose scroll position on every watcher reload. The load
    /// task reassigns both unconditionally when it completes. Each caller sets
    /// `pendingScrollAnchor` first (watcher → captured offset; reset paths → nil).
    private func triggerReload(source: String? = nil) {
        let generation = reloadGeneration + 1
        reloadSource = source.map {
            ReloadSource(generation: generation, source: $0)
        }
        reloadGeneration = generation
    }

    // MARK: - Watcher (Task 7)

    private func startWatcher() {
        watcher?.stop()
        watcher = DocumentFileWatcher(url: pane.fileURL) { [self] in
            triggerWatcherReload()
        }
        watcher?.start()
    }

    private func triggerWatcherReload() {
        watcherReloadTask?.cancel()
        watcherReloadGeneration += 1
        let generation = watcherReloadGeneration
        let anchor = scrollAnchorCapture?()
        let fileURL = pane.fileURL

        watcherReloadTask = Task.detached(priority: .userInitiated) { [self] in
            let onDisk = DocumentLoader.readSource(fileURL)
            guard !Task.isCancelled else { return }

            let context: (old: String?, isSelfWrite: Bool)? = await MainActor.run {
                guard !Task.isCancelled, generation == watcherReloadGeneration else { return nil }
                guard let onDisk else {
                    pendingScrollAnchor = nil
                    triggerReload()
                    watcherReloadTask = nil
                    return nil
                }

                let selfWrite = Self.selfWriteRegistry.context(
                    fileURL: fileURL,
                    onDiskSource: onDisk
                )
                // Self-write entries are shared across panes and intentionally
                // not consumed on match: every mounted watcher for this file
                // must be able to suppress the same awesoMux write. The core
                // registry expires entries after a short watcher window, which
                // bounds stale byte-for-byte suppression without breaking pane B.
                // Load-bearing ordering: renderedDoc is still the pre-reload
                // source here; if triggerReload ever mutates it synchronously,
                // this becomes new-vs-new and the revision indicator goes dark.
                // Debounced watcher bursts intentionally diff from the last
                // version the user saw — which is their own just-written
                // source when a self-write and an external edit coalesced.
                let old = selfWrite?.source ?? renderedDoc?.source
                pendingScrollAnchor = anchor
                triggerReload(source: onDisk)
                return (old, selfWrite?.isSelfWrite ?? false)
            }

            guard !Task.isCancelled, let context, let onDisk else { return }
            // The diff stays off the main actor: difference(from:) on a full
            // rewrite is too expensive for the thread that draws the UI, and
            // it only needs the two captured strings.
            let revision = LineDiffCount.forExternalEdit(
                old: context.old,
                new: onDisk,
                isSelfWrite: context.isSelfWrite
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled, generation == watcherReloadGeneration else { return }
                if let revision {
                    onRevision(revision)
                }
                watcherReloadTask = nil
            }
        }
    }

    // MARK: - Error message helpers

    private func rejectionMessage(
        for reason: DocumentURLValidator.Rejection,
        pane: DocumentPane
    ) -> String {
        let q = "\u{201C}\(pane.title)\u{201D}"
        switch reason {
        case .notFileURL:
            return "Can't open \(q): the path is not a local file URL."
        case .badExtension:
            let allowed = DocumentURLValidator.allowedExtensions.sorted().joined(separator: ", ")
            return "Can't open \(q): only these file types are supported: \(allowed)."
        case .tooLarge:
            let cap = DocumentURLValidator.maxFileSizeBytes / (1024 * 1024)
            return "Can't open \(q): file exceeds the \(cap) MB size limit."
        case .unreadable:
            return "Can't open \(q): the file couldn't be read (missing or no permission)."
        }
    }
}
