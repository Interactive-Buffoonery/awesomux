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

    private var nudgeResolution: DocumentNudgeTargetResolution {
        // Settings are read live per resolution (non-reactive source); a
        // toggle flipped after render is caught by the click-time re-resolve
        // in `performNudge`, the action-time safety floor.
        let integrations = runtime.agentIntegrations
        return Self.resolveNudgeTarget(
            in: session.layout,
            for: pane.id,
            isIntegrationEnabled: { kind in
                switch kind {
                case .claudeCode: integrations.claudeCode.enabled
                case .codex: integrations.codex.enabled
                case .openCode: integrations.openCode.enabled
                case .pi: integrations.pi.enabled
                case .grok: integrations.grok.enabled
                case .shell: false
                }
            },
            foregroundExecutableMatch: runtime.foregroundExecutableMatch
        )
    }

    static func resolveNudgeTarget(
        in layout: TerminalPaneLayout,
        for documentID: DocumentPane.ID,
        isIntegrationEnabled: (AgentKind) -> Bool,
        foregroundExecutableMatch: (String, TerminalPane.ID) -> ProcessLivenessProbe.ForegroundExecutableMatch
    ) -> DocumentNudgeTargetResolution {
        let resolution = layout.documentNudgeTarget(for: documentID)
        guard case .available(let target) = resolution else { return resolution }
        switch foregroundExecutableMatch("ssh", target.id) {
        case .matching:
            return .unavailable(.foregroundSSH)
        case .unknown:
            return .unavailable(.localTerminalUnverified)
        case .notMatching:
            break
        }
        // Verified-agent-prompt gate (INT-569): only `.matching` counts as
        // live evidence, so unknown probe results fail closed here too (the
        // SSH check above already declined the shared probe's `.unknown`).
        switch AgentPromptGate.verdict(
            agentKind: target.agentKind,
            agentState: target.agentState,
            isIntegrationEnabled: isIntegrationEnabled,
            matchesForegroundExecutable: { foregroundExecutableMatch($0, target.id) == .matching }
        ) {
        case .verified:
            return resolution
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }

    private func sendUnavailableDescription(
        for resolution: DocumentNudgeTargetResolution
    ) -> String? {
        guard case .unavailable(let reason) = resolution else { return nil }
        switch reason {
        case .foregroundSSH:
            return String(
                localized: "Exit SSH to send this local document path",
                comment: "Unavailable reason for sending a Mac-local document path while the terminal is inside manual SSH"
            )
        case .localTerminalUnverified:
            return String(
                localized: "Couldn't verify a local terminal for this document path",
                comment: "Unavailable reason for sending a Mac-local document path when foreground process evidence is unavailable"
            )
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
        case .noVerifiedAgent:
            return String(
                localized: "Sending is available when a supported agent is waiting in this document's terminal",
                comment: "Unavailable reason when the document's terminal is not running a verified supported agent"
            )
        case .agentIntegrationDisabled(let kind):
            return String(
                localized: "Enable the \(kind.shortName) integration in Settings to send",
                comment: "Unavailable reason when the target agent's integration is disabled in settings"
            )
        case .agentNotReceptive(let kind):
            return String(
                localized: "\(kind.shortName) isn't waiting for input yet",
                comment: "Unavailable reason when the target agent is not currently waiting at its prompt"
            )
        }
    }

    /// "Send to Claude" / "Send to Codex" / … only when the prompt gate verified
    /// the target agent (`AgentPromptGate` drives label, enabled state, and
    /// action from ONE verdict); generic "Send to Agent" otherwise, so the
    /// wording can never claim a verified agent while the action is unsafe.
    private func sendButtonTitle(
        for resolution: DocumentNudgeTargetResolution
    ) -> String {
        guard case .available(let target) = resolution else {
            return String(
                localized: "Send to Agent",
                comment: "Generic send-bar button title when no verified agent target exists"
            )
        }
        return String(
            localized: "Send to \(target.agentKind.shortName)",
            comment: "Send-bar button title naming the verified agent in the target terminal"
        )
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
                // Resolve once per render: the resolution issues live foreground
                // probes, and both the title and the unavailable description
                // derive from the same verdict anyway (one-verdict invariant).
                let resolution = nudgeResolution
                Spacer(minLength: 0)
                SendToAgentButton(
                    title: sendButtonTitle(for: resolution),
                    failed: nudgeFailed,
                    unavailableDescription: sendUnavailableDescription(for: resolution),
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
        //
        // Safety invariant: this click-time re-resolve (including the live
        // foreground probe inside the prompt gate) and the `sendText` below run
        // in one synchronous MainActor hop with no suspension between them —
        // the same atomicity standard the bridge consent path documents. Do
        // not introduce an `await` between the gate and the write.
        let resolution = nudgeResolution
        guard case .available(let targetPane) = resolution else {
            reportNudgeUnavailable(resolution)
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

    private func reportNudgeUnavailable(_ resolution: DocumentNudgeTargetResolution) {
        nudgeFailed = true
        TerminalAccessibilityAnnouncer.announce(
            sendUnavailableDescription(for: resolution)
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
        let snapshot: MarkdownDocumentSnapshot
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
    @State private var documentNoteSheetSnapshot: MarkdownDocumentSnapshot? = nil
    @State private var lastSelfWrittenSource: String? = nil
    @State private var reloadGeneration: Int = 0
    @State private var reloadSource: ReloadSource? = nil
    @State private var reloadCompletion = DocumentReloadCompletion()
    @State private var renderTask: Task<(DocumentLoader.LoadResult, RenderedDocument?)?, Never>? = nil

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

    private var currentSnapshot: MarkdownDocumentSnapshot? {
        guard case let .loaded(_, _, snapshot) = loadResult else { return nil }
        return snapshot
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
                case let .loaded(blocks, _, snapshot):
                    loadedView(blocks: blocks, snapshot: snapshot)

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
            reloadCompletion = DocumentReloadCompletion()
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
            renderTask?.cancel()
            renderTask = nil
            reloadCompletion.invalidate()
            nsPopover?.close()
            nsPopover = nil
        }
        .task(id: reloadTaskID) {
            let snapshot = capturedReloadSource.flatMap {
                $0.generation == reloadTaskID.generation ? $0.snapshot : nil
            }
            if reloadSource?.generation == reloadTaskID.generation {
                reloadSource = nil
            }
            // Reuse the current document when the on-disk source is unchanged:
            // the build is a pure function of the source, so a remount seeded
            // from the tab cache (or a watcher wobble) skips the whole
            // attributed rebuild (INT-748 PR2).
            let priorDoc = renderedDoc
            renderTask?.cancel()
            let task = Task.detached(priority: .userInitiated) {
                await DocumentLoader.loadAndRender(
                    load: {
                        snapshot.map {
                            guard let source = $0.source else {
                                return DocumentLoader.LoadResult.readError(
                                    "The file couldn’t be opened because it isn’t in the correct format.")
                            }
                            return .loaded(
                                MarkdownRenderModelBuilder.build(source),
                                source: source,
                                snapshot: $0
                            )
                        }
                            ?? DocumentLoader.load(reloadTaskID.fileURL)
                    },
                    priorDocument: priorDoc,
                    render: { AttributedMarkdownBuilder.build($0) }
                )
            }
            renderTask = task
            let output = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }

            guard let (result, doc) = output,
                !Task.isCancelled,
                reloadTaskID.fileURL == pane.fileURL,
                reloadTaskID.generation == reloadGeneration
            else { return }
            renderTask = nil
            renderedDoc = doc
            loadResult = result
            reloadCompletion.complete(reloadTaskID.generation)
            // Report only when the content actually changed (source compare is
            // O(1) on the reuse path — same String storage). An unchanged
            // reload re-storing an identical entry would invalidate the whole
            // group view for nothing on every watcher wobble; the cache
            // already holds this content (it seeded us or stored the first
            // load). Errors (doc == nil) always report — rare, and the cache
            // should stop seeding content the disk can no longer back.
            if doc == nil || priorDoc == nil
                || doc?.source.utf8.elementsEqual(priorDoc?.source.utf8 ?? "".utf8) == false
            {
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
    private func loadedView(
        blocks: [MarkdownBlock],
        snapshot: MarkdownDocumentSnapshot?
    ) -> some View {
        if let doc = renderedDoc, let snapshot {
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
                        documentAnnotationBar(doc: doc, snapshot: snapshot)
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
                                    doc: doc,
                                    snapshot: snapshot
                                )
                            },
                            onAddPillClicked: { pillRect, anchorView in
                                // Secondary affordance: still works if user clicks the add pill.
                                guard !isReadOnly, let span = selectedSourceSpan, !spanTouchesMark else { return }
                                showComposePopover(
                                    span: span,
                                    pillRect: pillRect,
                                    anchorView: anchorView,
                                    doc: doc,
                                    snapshot: snapshot
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
                                    doc: doc,
                                    snapshot: snapshot
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
                                            doc: doc,
                                            snapshot: snapshot
                                        )
                                    }
                                }
                                .disabled(selectedSourceSpan == nil || spanTouchesMark)

                                Button(doc.documentNote == nil ? "Add Document Note…" : "Document Note…") {
                                    documentNoteSheetDoc = doc
                                    documentNoteSheetSnapshot = snapshot
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
                            documentNoteSheetSnapshot = nil
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
                if let noteDoc = documentNoteSheetDoc,
                    let noteSnapshot = documentNoteSheetSnapshot
                {
                    DocumentNoteSheet(
                        note: noteDoc.documentNote,
                        onAdd: { note in
                            let outcome = await addDocumentNote(note, doc: noteDoc, snapshot: noteSnapshot)
                            if outcome == .saved {
                                TerminalAccessibilityAnnouncer.announce(
                                    String(
                                        localized: "Document note added", comment: "VoiceOver announcement after adding the document note")
                                )
                            }
                            return outcome
                        },
                        onEdit: { id, newNote in
                            let outcome = await updateAnnotationPayload(
                                id: id,
                                payload: newNote,
                                doc: noteDoc,
                                snapshot: noteSnapshot
                            )
                            if outcome == .saved {
                                TerminalAccessibilityAnnouncer.announce(
                                    String(
                                        localized: "Document note updated",
                                        comment: "VoiceOver announcement after editing the document note")
                                )
                            }
                            return outcome
                        },
                        onSetStatus: { id, status in
                            let outcome = await setAnnotationStatus(
                                id: id,
                                status: status,
                                doc: noteDoc,
                                snapshot: noteSnapshot
                            )
                            if outcome == .saved {
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
                            return outcome
                        },
                        onDelete: { id in
                            let outcome = await deleteAnnotation(id: id, doc: noteDoc, snapshot: noteSnapshot)
                            if outcome == .saved {
                                TerminalAccessibilityAnnouncer.announce(
                                    String(
                                        localized: "Document note deleted",
                                        comment: "VoiceOver announcement after deleting the document note")
                                )
                            }
                            return outcome
                        },
                        onClose: {
                            documentNoteSheetDoc = nil
                            documentNoteSheetSnapshot = nil
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
    private func documentAnnotationBar(
        doc: RenderedDocument,
        snapshot: MarkdownDocumentSnapshot
    ) -> some View {
        let documentNote = doc.documentNote
        let resolvedCount = doc.resolvedAnnotationCount
        return HStack {
            if !pane.isReadOnlySnapshot || documentNote != nil {
                Button {
                    documentNoteSheetDoc = doc
                    documentNoteSheetSnapshot = snapshot
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
        doc: RenderedDocument,
        snapshot: MarkdownDocumentSnapshot
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
                onEdit: { [weak popover] newNote in
                    let outcome = await updateAnnotationPayload(
                        id: markID,
                        payload: newNote,
                        doc: doc,
                        snapshot: snapshot
                    )
                    if outcome == .saved {
                        popover?.close()
                        TerminalAccessibilityAnnouncer.announce(
                            String(localized: "Annotation updated", comment: "VoiceOver announcement after editing an annotation's note")
                        )
                    }
                    return outcome
                },
                onDelete: { [weak popover] in
                    let outcome = await deleteAnnotation(id: markID, doc: doc, snapshot: snapshot)
                    if outcome == .saved {
                        popover?.close()
                        TerminalAccessibilityAnnouncer.announce(
                            String(localized: "Annotation deleted", comment: "VoiceOver announcement after deleting an annotation")
                        )
                    }
                    return outcome
                },
                onSetStatus: { [weak popover] status in
                    let outcome = await setAnnotationStatus(
                        id: markID,
                        status: status,
                        doc: doc,
                        snapshot: snapshot
                    )
                    if outcome == .saved {
                        popover?.close()
                        TerminalAccessibilityAnnouncer.announce(
                            status == .resolved
                                ? String(
                                    localized: "Annotation resolved", comment: "VoiceOver announcement after marking an annotation resolved"
                                )
                                : String(localized: "Annotation reopened", comment: "VoiceOver announcement after reopening an annotation")
                        )
                    }
                    return outcome
                },
                onReply: { [weak popover] reply in
                    let outcome = await replyToAnnotation(
                        id: markID,
                        reply: reply,
                        doc: doc,
                        snapshot: snapshot
                    )
                    if outcome == .saved {
                        popover?.close()
                        TerminalAccessibilityAnnouncer.announce(
                            annotation.status == .resolved
                                ? String(
                                    localized: "Reply added, annotation reopened",
                                    comment: "VoiceOver announcement after replying to a resolved annotation, which reopens it")
                                : String(localized: "Reply added", comment: "VoiceOver announcement after replying to an annotation")
                        )
                    }
                    return outcome
                },
                allowsEditing: !pane.isReadOnlySnapshot,
                onSubmissionChanged: { [weak popover] isSubmitting in
                    popover?.behavior = AnnotationPopoverLifecycle.behavior(
                        isSubmitting: isSubmitting
                    )
                }
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
        doc: RenderedDocument,
        snapshot: MarkdownDocumentSnapshot
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
                    let outcome = await insertAnnotation(
                        span: span,
                        intent: intent,
                        payload: note,
                        doc: doc,
                        snapshot: snapshot
                    )
                    if outcome == .saved {
                        popover?.close()
                        TerminalAccessibilityAnnouncer.announce(
                            String(localized: "Annotation added", comment: "VoiceOver announcement after adding a new annotation")
                        )
                    }
                    return outcome
                },
                onCancel: { [weak popover] in
                    popover?.close()
                },
                onSubmissionChanged: { [weak popover] isSubmitting in
                    popover?.behavior = AnnotationPopoverLifecycle.behavior(
                        isSubmitting: isSubmitting
                    )
                }
            ))
        popover.contentViewController = hosting
        hosting.view.layoutSubtreeIfNeeded()
        popover.contentSize = hosting.view.fittingSize
        hosting.sizingOptions = [.preferredContentSize]
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

    private func insertAnnotation(
        span: Range<Int>,
        intent: PlanAnnotationIntent,
        payload: String,
        doc: RenderedDocument,
        snapshot: MarkdownDocumentSnapshot
    ) async -> AnnotationSaveOutcome {
        if SelectionSourceMapping.spanTouchesExistingMark(span, in: doc) {
            showNestedMarkAlert(span: span, doc: doc)
            return .failed
        }
        return await guardedWrite(
            observed: snapshot,
            conflictOutcome: .copyAndReselect
        ) { freshSource in
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

    private func updateAnnotationPayload(
        id: String,
        payload: String,
        doc: RenderedDocument,
        snapshot: MarkdownDocumentSnapshot
    ) async -> AnnotationSaveOutcome {
        await writeExistingAnnotation(id: id, doc: doc, snapshot: snapshot) { source in
            PlanAnnotationWriter.updatingAnnotation(id: id, in: source) {
                $0.payload = payload
            }
        }
    }

    private func setAnnotationStatus(
        id: String,
        status: PlanAnnotationStatus,
        doc: RenderedDocument,
        snapshot: MarkdownDocumentSnapshot
    ) async -> AnnotationSaveOutcome {
        await writeExistingAnnotation(id: id, doc: doc, snapshot: snapshot) { source in
            PlanAnnotationWriter.updatingAnnotation(id: id, in: source) {
                $0.status = status
            }
        }
    }

    private func addDocumentNote(
        _ note: String,
        doc: RenderedDocument,
        snapshot: MarkdownDocumentSnapshot
    ) async -> AnnotationSaveOutcome {
        guard
            let observed = AnnotationSaveRecovery.snapshotForNewDocumentNote(
                openedSnapshot: snapshot,
                currentSnapshot: currentSnapshot,
                currentDocument: renderedDoc
            )
        else { return .copyOnly }

        return await guardedWrite(
            observed: observed,
            conflictOutcome: .reloadAndRetry
        ) { freshSource in
            PlanAnnotationWriter.appendingDocumentAnnotation(
                in: freshSource, author: .user, payload: note
            )?.source
        }
    }

    private func replyToAnnotation(
        id: String,
        reply: String,
        doc: RenderedDocument,
        snapshot: MarkdownDocumentSnapshot
    ) async -> AnnotationSaveOutcome {
        await writeExistingAnnotation(id: id, doc: doc, snapshot: snapshot) { source in
            PlanAnnotationWriter.appendingNote(
                to: id,
                in: source,
                author: .user,
                payload: reply
            )
        }
    }

    private func deleteAnnotation(
        id: String,
        doc: RenderedDocument,
        snapshot: MarkdownDocumentSnapshot
    ) async -> AnnotationSaveOutcome {
        await writeExistingAnnotation(id: id, doc: doc, snapshot: snapshot) { source in
            PlanAnnotationWriter.removingAnnotation(id: id, in: source)
        }
    }

    private func writeExistingAnnotation(
        id: String,
        doc: RenderedDocument,
        snapshot: MarkdownDocumentSnapshot,
        writer: @escaping @Sendable (String) -> String?
    ) async -> AnnotationSaveOutcome {
        let observed: MarkdownDocumentSnapshot
        if let currentSnapshot,
            currentSnapshot != snapshot,
            AnnotationSaveRecovery.canRebind(
                annotationID: id,
                openedDocument: doc,
                currentDocument: renderedDoc
            )
        {
            observed = currentSnapshot
        } else if currentSnapshot == snapshot {
            observed = snapshot
        } else {
            return .copyOnly
        }

        return await guardedWrite(
            observed: observed,
            conflictOutcome: .reloadAndRetry,
            writer: writer
        )
    }

    private func guardedWrite(
        observed: MarkdownDocumentSnapshot,
        conflictOutcome: AnnotationSaveOutcome,
        writer: @escaping @Sendable (String) -> String?
    ) async -> AnnotationSaveOutcome {
        guard !pane.isReadOnlySnapshot else {
            showAlert(title: "Read-Only Snapshot", message: "Remote Markdown snapshots cannot be edited in awesoMux yet.")
            return .failed
        }

        let fileURL = pane.fileURL
        let reloadCompletion = reloadCompletion
        let result = await Task.detached(priority: .userInitiated) {
            MarkdownDocumentCommitter.commitObserved(
                at: fileURL,
                observed: observed,
                transform: writer
            )
        }.value

        switch result {
        case .committed(let newSource):
            Self.selfWriteRegistry.record(fileURL: fileURL, source: newSource)
            return .saved
        case .observedConflict:
            guard !reloadCompletion.isInvalidated else { return .failed }
            pendingScrollAnchor = nil
            let generation = triggerReload()
            guard await reloadCompletion.wait(for: generation) else { return .failed }
            return conflictOutcome
        case .unreadable:
            showAlert(title: "Couldn't Save", message: "The document couldn't be read from disk.")
        case .invalidEdit:
            showAlert(
                title: "Couldn't Save",
                message: "The annotation couldn't be saved. It may be too long, invalid, or duplicated."
            )
        case .outputTooLarge:
            showAlert(title: "Couldn't Save", message: "The edited document would be too large.")
        case .failed(let failure):
            showAlert(title: "Couldn't Save", message: failure.message)
        }
        return .failed
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
    @discardableResult
    private func triggerReload(snapshot: MarkdownDocumentSnapshot? = nil) -> Int {
        renderTask?.cancel()
        renderTask = nil
        let generation = reloadGeneration + 1
        reloadSource = snapshot.map {
            ReloadSource(generation: generation, snapshot: $0)
        }
        reloadGeneration = generation
        return generation
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
            let onDisk = DocumentLoader.readSnapshot(fileURL)
            guard !Task.isCancelled else { return }

            let context: (old: String?, isSelfWrite: Bool)? = await MainActor.run {
                guard !Task.isCancelled, generation == watcherReloadGeneration else { return nil }
                guard let onDisk else {
                    pendingScrollAnchor = nil
                    triggerReload()
                    watcherReloadTask = nil
                    return nil
                }

                guard let onDiskSource = onDisk.source else {
                    pendingScrollAnchor = nil
                    triggerReload()
                    watcherReloadTask = nil
                    return nil
                }
                let selfWrite = Self.selfWriteRegistry.context(
                    fileURL: fileURL,
                    onDiskSource: onDiskSource
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
                triggerReload(snapshot: onDisk)
                return (old, selfWrite?.isSelfWrite ?? false)
            }

            guard !Task.isCancelled, let context, let onDisk, let onDiskSource = onDisk.source else { return }
            // The diff stays off the main actor: difference(from:) on a full
            // rewrite is too expensive for the thread that draws the UI, and
            // it only needs the two captured strings.
            let revision = LineDiffCount.forExternalEdit(
                old: context.old,
                new: onDiskSource,
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
