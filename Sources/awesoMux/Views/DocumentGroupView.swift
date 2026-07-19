import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import SwiftUI

// MARK: - DocumentGroupView

/// The session's document viewer: `DocumentTabStripView` over the selected
/// tab's `DocumentPaneView` and send bar (or the inline file browser).
struct DocumentGroupView: View {
    let document: DocumentPane
    // Fully qualified: SwiftUI declares its own `DocumentGroup` scene type.
    let group: AwesoMuxCore.DocumentGroup
    let session: TerminalSession
    let sessionStore: SessionStore
    let runtime: GhosttyRuntime

    @State private var mode: DocumentPaneMode = .document
    // INT-754: composer presentation is owned here, ABOVE DocumentPaneSendBar's
    // shell-activity-keyed `.id`, so a target-pane activity flip that rebuilds the
    // send bar can't tear the open composer down and lose the in-flight draft. The
    // context PINS the document + target pane resolved when the composer opened, so
    // a tab switch while it's open can't retarget the send or the focus restore.
    @State private var composerContext: ComposerContext?
    @State private var composerFocusPaneID: TerminalPane.ID?
    // INT-683: tracks the document's comment count across reloads to detect the
    // "all comments resolved" (> 0 -> 0) transition, and whether the resulting
    // inline notice is currently shown in the send bar.
    @State private var commentResolution = CommentResolutionTracker()
    @State private var showAllResolvedNotice = false
    // Pending settle window between a > 0 -> 0 candidate and its confirmation —
    // a non-atomic agent rewrite can read as a transient comment-free file, so
    // the drop must persist across this interval before the notice shows.
    @State private var settleTask: Task<Void, Never>?
    // INT-748 PR2: per-tab render + scroll-position session-memory so a tab
    // switch neither flashes a spinner nor loses the reading position.
    @State private var tabMemory = DocumentTabMemory()
    // Full revision details yield to a compact per-tab marker after a short
    // active-view dwell. The marker keeps the counts recoverable until the
    // user dismisses it, even when edits land while another app is active.
    @State private var revisionIndicators = DocumentRevisionIndicatorState()
    @State private var revisionInteractionActive = false
    // The mounted tab's scroll-anchor capture, tagged with its tab id: on a
    // selection change the group snapshots the OUTGOING tab's position, and the
    // tag guarantees a closure that already belongs to the incoming tab can't
    // corrupt the outgoing tab's saved anchor. Written during the
    // representable's update pass (like DocumentPaneView's own capture slot) —
    // safe ONLY while no `body` ever reads it; keep reads inside event and
    // onChange closures.
    @State private var scrollAnchorCapture: (tabID: DocumentPane.ID, capture: @MainActor () -> Int?)?

    // Read in this ungated body and handed to the strip by value — the strip's
    // .equatable() gate can't be trusted to pass env invalidation through.
    @Environment(\.awAccent) private var accentResolver
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(DocumentComposeTabActionHandler.self) private var documentTabActions
    @Environment(AppSettingsStore.self) private var appSettingsStore

    private static let resolveSettleInterval: Duration = .milliseconds(500)
    private static let revisionExpandedDuration: Duration = .seconds(9)

    private struct RevisionAutoCollapseTaskID: Equatable {
        let generation: Int?
        let canRun: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            // The strip's height includes the focus-accent reservation the
            // terminal panes render as a separate band (see
            // DocumentTabStripView.height), so no spacer is stacked here.
            DocumentTabStripView(
                group: group,
                isBrowsingFiles: mode == .files,
                canBrowseFiles: !document.isReadOnlySnapshot,
                filesToggleHelp: filesToggleHelp,
                accent: accentResolver.accent,
                increasedContrast: colorSchemeContrast == .increased,
                selectedTaskProgress: selectedTaskProgress,
                revisionIndicators: revisionIndicators,
                onSelectTab: { tabID in
                    // Clicking the already-selected pill while the Files
                    // browser is open must still mean "show me this document" —
                    // the store treats same-tab selection as a no-op, so the
                    // cross-tab path's mode reset (the path onChange below)
                    // never fires for it.
                    if tabID == group.selectedTabID {
                        mode = .document
                        return
                    }
                    documentTabActions.perform {
                        sessionStore.selectDocumentTab(tabID: tabID, in: session.id)
                    }
                },
                onCloseTab: { tab in
                    let closeTab = {
                        let closedTitle = tab.title
                        sessionStore.closeDocumentPane(
                            documentID: tab.id,
                            in: session.id
                        )
                        // Mirror the terminal close X's "Pane closed" announcement:
                        // the close either swaps a neighbor tab in (its own
                        // announcement follows via onChange) or collapses the
                        // viewer — both invisible to VoiceOver without this.
                        TerminalAccessibilityAnnouncer.announce(
                            String(
                                localized: "Closed \(closedTitle)",
                                comment: "VoiceOver announcement after closing a document tab"
                            )
                        )
                    }
                    if tab.id == group.selectedTabID {
                        documentTabActions.perform(closeTab)
                    } else {
                        closeTab()
                    }
                },
                onExpandRevision: { tab in
                    if tab.id == group.selectedTabID {
                        revisionIndicators.expand(for: tab)
                        revisionInteractionActive = false
                        mode = .document
                    } else {
                        documentTabActions.perform {
                            revisionIndicators.expand(for: tab)
                            revisionInteractionActive = false
                            sessionStore.selectDocumentTab(tabID: tab.id, in: session.id)
                        }
                    }
                },
                onDismissRevision: {
                    revisionIndicators.dismiss(for: document)
                    revisionInteractionActive = false
                },
                onRevisionInteractionChanged: { active in
                    revisionInteractionActive = active
                },
                onToggleFiles: {
                    guard !document.isReadOnlySnapshot else { return }
                    // Entering Files mode unmounts DocumentPaneView, killing
                    // the capture closure's coordinator. Snapshot the reading
                    // position NOW (so the round trip restores where the user
                    // actually was, not the last tab-switch position) and
                    // release the registration — a dead capture returns nil,
                    // which storeScrollAnchor would treat as "scrolled to top"
                    // and use to erase a real saved anchor (review panel +
                    // adversarial pass, convergent).
                    if mode == .document {
                        if let scrollAnchorCapture,
                            scrollAnchorCapture.tabID == document.id
                        {
                            tabMemory.storeScrollAnchor(
                                scrollAnchorCapture.capture(),
                                for: document
                            )
                        }
                        scrollAnchorCapture = nil
                        revisionIndicators.collapse(for: document)
                        revisionInteractionActive = false
                    }
                    mode = mode == .files ? .document : .files
                }
            )
            .equatable()
            switch mode {
            case .document:
                DocumentPaneView(
                    pane: document,
                    cachedRender: tabMemory.render(for: document),
                    initialScrollAnchor: tabMemory.scrollAnchor(for: document),
                    onCommentCountChanged: { count in
                        if commentResolution.observe(commentCount: count) {
                            // Candidate resolve: wait out the settle window so a
                            // transient zero from a non-atomic rewrite can't
                            // flash the notice. confirmResolve() double-checks
                            // the drop is still standing when the timer fires.
                            settleTask?.cancel()
                            let fileName = document.fileURL.lastPathComponent
                            settleTask = Task { @MainActor in
                                try? await Task.sleep(for: Self.resolveSettleInterval)
                                guard !Task.isCancelled else { return }
                                if commentResolution.confirmResolve() {
                                    showAllResolvedNotice = true
                                    // The inline notice is invisible to screen
                                    // readers (WCAG 4.1.3); name the file so users
                                    // with several documents open know which one.
                                    TerminalAccessibilityAnnouncer.announce(
                                        String(
                                            localized: "\(fileName): all comments resolved",
                                            comment: "VoiceOver announcement when a document's last review comment is resolved"
                                        )
                                    )
                                }
                            }
                        } else if count > 0 {
                            // Comments came back (a new one was added after a
                            // resolve) — retract a stale notice immediately and
                            // cancel any settle window in flight.
                            settleTask?.cancel()
                            showAllResolvedNotice = false
                        }
                    },
                    onRenderCompleted: { render in
                        tabMemory.storeRender(render, for: document)
                    },
                    // A link inside a document inherits the CURRENT tab's
                    // terminal, not the active pane's (INT-748 PR2).
                    onOpenDocumentLink: { url in
                        guard !document.isReadOnlySnapshot else { return }
                        // Re-assert the router's contract at the sink: the old
                        // GhosttyRuntime.openURL path re-ran this exact check,
                        // and a future caller that skips the router shouldn't
                        // get a free pass into the tab model (review finding).
                        guard let documentURL = MarkdownLinkIntercept.documentURL(forFileURL: url) else { return }
                        // Preserve the source tab's association only when it is
                        // still live. A stale id must not poison an existing
                        // nil-associated tab during same-file dedup, and nil stays
                        // nil so Send to Agent can use its deterministic recovery path.
                        let liveAssociation = document.associatedTerminalPaneID.flatMap {
                            session.layout.pane(id: $0)?.id
                        }
                        sessionStore.openDocumentPane(
                            fileURL: documentURL,
                            in: session.id,
                            associatedWith: liveAssociation,
                            associationPolicy: .preserveNil
                        )
                    },
                    onRevision: { diff in
                        revisionIndicators.record(diff, for: document)
                        // A VoiceOver user who isn't parked on the tab strip
                        // never encounters the pill, so announce the
                        // appearance — same reasoning as the send bar's
                        // nudge-failure and the all-resolved notice.
                        TerminalAccessibilityAnnouncer.announce(
                            diff.accessibilityAnnouncement(documentTitle: document.title)
                        )
                    },
                    onRegisterScrollAnchorCapture: { capture in
                        scrollAnchorCapture = (document.id, capture)
                    }
                )
                .id(document.fileURL.standardizedFileURL.path)
                DocumentPaneSendBar(
                    pane: document,
                    session: session,
                    runtime: runtime,
                    showAllResolvedNotice: $showAllResolvedNotice,
                    onCompose: presentComposer
                )
                // Fresh identity per tab so a failure state (Peach button) from
                // one tab never bleeds into the next tab's healthy send bar. A
                // shell-activity flip is the existing event-driven invalidation
                // for command submit/finish, so leaving manual SSH also forces a
                // fresh foreground check without polling. Agent kind/state
                // flips invalidate the same way so the prompt gate's label and
                // enabled state track the target's hook-driven transitions
                // (running -> waiting) without polling (INT-569).
                .id(
                    DocumentNudgeSendBarID(
                        documentID: document.id,
                        target: session.layout.documentSendTarget(for: document.id)
                    )
                )
            case .files:
                DocumentFileBrowserView(
                    rootURL: markdownBrowserRootURL,
                    currentFileURL: document.fileURL,
                    onOpen: { fileURL in
                        if sessionStore.replaceDocumentPane(
                            documentID: document.id,
                            fileURL: fileURL,
                            in: session.id
                        ) {
                            mode = .document
                        }
                    },
                    onCancel: {
                        mode = .document
                    }
                )
            }
        }
        .sheet(item: $composerContext, onDismiss: restoreFocusAfterComposer) { context in
            RichInputComposerSheet(
                seed: context.seed,
                title: String(localized: "Send to Agent", comment: "Title of the multiline prompt composer"),
                onSend: { stageComposerText($0, in: context) },
                onClose: { composerContext = nil }
            )
        }
        // One handler for both selection changes and tab-set changes so the
        // capture-then-prune order is deterministic (two separate onChange
        // modifiers give no ordering guarantee, and pruning before capturing
        // would resurrect a just-closed tab's memory entry).
        .onChange(of: group) { oldGroup, newGroup in
            if oldGroup.selectedTabID != newGroup.selectedTabID,
                let scrollAnchorCapture,
                scrollAnchorCapture.tabID == oldGroup.selectedTabID,
                let outgoingTab = oldGroup.tab(id: oldGroup.selectedTabID)
            {
                // Snapshot the outgoing tab's reading position while its text
                // view is still mounted (onChange runs before the remount
                // commits). If the registration has already moved to the
                // incoming tab, the tag mismatch skips the capture — losing one
                // anchor beats saving the wrong tab's position.
                tabMemory.storeScrollAnchor(
                    scrollAnchorCapture.capture(),
                    for: outgoingTab
                )
            }
            if oldGroup.selectedTabID != newGroup.selectedTabID,
                let outgoingTab = oldGroup.tab(id: oldGroup.selectedTabID)
            {
                revisionIndicators.collapse(for: outgoingTab)
                revisionInteractionActive = false
            }
            tabMemory.prune(keeping: newGroup.tabs)
            revisionIndicators.prune(keeping: newGroup.tabs)
        }
        // Same key as DocumentPaneView's .id above so the tracker reset and the
        // child remount agree on what counts as "a different file".
        .onChange(of: document.fileURL.standardizedFileURL.path) { _, _ in
            // Switching the pane to a different file starts a fresh tracker: the
            // new file's first count is an initial load, not a resolve of the old
            // file's comments. Also drop any notice left over from the old file.
            settleTask?.cancel()
            commentResolution = CommentResolutionTracker()
            showAllResolvedNotice = false
            revisionIndicators.prune(keeping: group.tabs)
            revisionInteractionActive = false
            // A tab switch always lands on the new tab's document. Without this
            // reset, a Files browser opened on tab A survives an async
            // selection change (agent hook, dedup select) and its next commit
            // replaces whichever tab won selection in the meantime (INT-748).
            mode = .document
            // The single announcement for EVERY selection path — strip click,
            // keyboard next/previous-tab, dedup open, agent hook. The strip's
            // pills don't announce on their own, so this doesn't double-speak.
            TerminalAccessibilityAnnouncer.announce(
                String(
                    localized: "Now showing \(document.title)",
                    comment: "VoiceOver announcement when the visible document tab changes"
                )
            )
        }
        // The settle task is cancelled on tab switch by the onChange above, but
        // the viewer itself can unmount (last tab closed, session closed) with
        // the 500 ms window still pending — and its announcement is a side
        // effect VoiceOver would speak for a document that no longer exists.
        .onDisappear {
            settleTask?.cancel()
        }
        .task(id: revisionAutoCollapseTaskID) {
            guard revisionAutoCollapseTaskID.canRun,
                let indicator = revisionIndicators.indicator(for: document)
            else {
                return
            }
            let generation = indicator.generation
            let clock = ContinuousClock()
            let startedAt = clock.now
            let remaining =
                revisionIndicators.remainingExpandedTime(
                    of: Self.revisionExpandedDuration,
                    for: document
                ) ?? Self.revisionExpandedDuration
            if remaining > .zero {
                do {
                    try await Task.sleep(for: remaining)
                } catch {
                    revisionIndicators.recordActiveViewingTime(
                        clock.now - startedAt,
                        for: document,
                        generation: generation
                    )
                    return
                }
            }
            revisionIndicators.recordActiveViewingTime(
                clock.now - startedAt,
                for: document,
                generation: generation
            )
            guard revisionAutoCollapseTaskID.canRun,
                let current = revisionIndicators.indicator(for: document),
                current.generation == generation,
                current.presentation == .expanded
            else {
                return
            }
            revisionIndicators.collapse(for: document)
        }
    }

    private var revisionAutoCollapseTaskID: RevisionAutoCollapseTaskID {
        let indicator = revisionIndicators.indicator(for: document)
        return RevisionAutoCollapseTaskID(
            generation: indicator?.generation,
            canRun: indicator?.presentation == .expanded
                && mode == .document
                && controlActiveState != .inactive
                && !revisionInteractionActive
        )
    }

    private var markdownBrowserRootURL: URL? {
        // Browse root prefers the tab's stored terminal association (INT-748).
        // Unlike the send button this falls back to the active pane — a browse
        // root is cosmetic, so a nil OR dangling association degrades to the
        // active terminal's folder instead of an empty browser. Resolving the
        // pane (not just the id) is what makes the dangling case actually
        // reach the fallback.
        let targetPane =
            document.associatedTerminalPaneID
            .flatMap { session.layout.pane(id: $0) }
            ?? session.layout.pane(id: session.activePaneID)
        guard
            let directory = WorkingDirectoryValidator.firstValidatedReportedDirectory(from: [
                targetPane?.workingDirectory,
                session.workingDirectory,
            ])
        else {
            return nil
        }
        return URL(fileURLWithPath: directory, isDirectory: true)
    }

    private var selectedTaskProgress: TaskProgress? {
        guard let progress = tabMemory.render(for: document)?.renderedDoc?.taskProgress,
            progress.total > 0
        else {
            return nil
        }
        return progress
    }

    private var filesToggleHelp: String {
        if let origin = document.remoteSnapshotOrigin {
            return String(
                localized: "Remote snapshot from \(origin)",
                comment: "Help text for the Files toggle when the visible document is a read-only remote snapshot"
            )
        }
        if mode == .files {
            return String(
                localized: "Back to \(document.title)",
                comment: "Help text for the Files toggle while the file browser is showing"
            )
        }
        guard let rootURL = markdownBrowserRootURL else {
            return String(
                localized: "Show Markdown files from this document's terminal folder",
                comment: "Help text for the Files toggle when no browse folder is known yet"
            )
        }
        return String(
            localized: "Show Markdown files in \(rootURL.path)",
            comment: "Help text for the Files toggle naming the folder it will browse"
        )
    }

    // MARK: - Composer

    /// Opens the composer, pinning the document + resolved target it targets.
    /// Silently no-ops if the target is ineligible at open (the send button
    /// already gated on availability; this only loses the rare open-time race).
    private func presentComposer() {
        guard case .available(let target) = resolveSendTarget(for: document.id) else { return }
        let displayPath = DocumentPaneSendBar.resolveDisplayPath(
            for: document.fileURL,
            relativeTo: target.workingDirectory
        )
        composerFocusPaneID = target.id
        composerContext = ComposerContext(
            documentID: document.id,
            targetPaneID: target.id,
            seed: NudgeComposer.text(displayPath: displayPath)
        )
    }

    /// Restores first responder to the pinned target terminal when the composer
    /// closes (Cancel, Esc, close button, or a successful send) so keyboard/
    /// VoiceOver focus isn't stranded. Uses the captured pane id — which
    /// `focusSurface` safely no-ops for if it died — rather than re-running the
    /// eligibility probe, so an SSH/unverifiable target still restores focus.
    private func restoreFocusAfterComposer() {
        guard let paneID = composerFocusPaneID else { return }
        runtime.focusSurface(toPane: paneID)
        composerFocusPaneID = nil
    }

    /// Deterministic send target for a document — the same resolver the send bar
    /// uses, so nil associations recover to a direct sibling and stale explicit
    /// ones fail closed. Keyed by document id (not the current selection) so a
    /// pinned composer resolves against session.layout regardless of the tab shown.
    private func resolveSendTarget(for documentID: DocumentPane.ID) -> DocumentNudgeTargetResolution {
        let integrations = appSettingsStore.agentIntegrations.value
        return DocumentPaneSendBar.resolveNudgeTarget(
            in: session.layout,
            for: documentID,
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
            agentBinaryPath: { kind in
                switch kind {
                case .claudeCode: integrations.claudeCode.binaryPath
                case .codex: integrations.codex.binaryPath
                case .openCode: integrations.openCode.binaryPath
                case .pi: integrations.pi.binaryPath
                case .grok: integrations.grok.binaryPath
                case .shell: nil
                }
            },
            foregroundComm: { runtime.foregroundComm(in: $0) },
            foregroundGeneration: { runtime.foregroundGeneration(in: $0) },
            verifiedWaitingForegroundGeneration: { runtime.verifiedWaitingForegroundGeneration(in: $0) }
        )
    }

    /// Stages the composed draft into the PINNED target terminal. Re-resolves the
    /// pinned document at submit (the target may have died or its association
    /// changed while the composer was open) and refuses to send if the resolved
    /// target no longer matches — a tab switch can't retarget the paste. The
    /// payload is control-char sanitized before it reaches the live PTY. `.failed`
    /// keeps the composer open with the draft intact.
    private func stageComposerText(_ draft: String, in context: ComposerContext) -> RichInputSendResult {
        let resolution = resolveSendTarget(for: context.documentID)
        guard case .available(let target) = resolution, target.id == context.targetPaneID else {
            let reason: String
            if case .unavailable(let why) = resolution {
                reason = DocumentPaneSendBar.unavailableDescription(for: why)
            } else {
                reason = String(
                    localized: "Couldn't send — this document's terminal isn't available",
                    comment: "Composer failure when a document has no eligible send target"
                )
            }
            TerminalAccessibilityAnnouncer.announce(reason)
            return .failed(reason)
        }
        let payload = RichInputStaging.stagedPayload(draft)
        guard !payload.isEmpty else {
            let reason = String(
                localized: "Nothing to send",
                comment: "Composer failure when the draft is empty after sanitizing"
            )
            TerminalAccessibilityAnnouncer.announce(reason)
            return .failed(reason)
        }
        if runtime.sendText(payload, toPane: context.targetPaneID) {
            TerminalAccessibilityAnnouncer.announce(
                String(
                    localized: "Pasted into this document's terminal — press Return there to send",
                    comment: "VoiceOver announcement after staging composed text into the associated terminal prompt"
                )
            )
            return .sent
        }
        let reason = String(
            localized: "Couldn't send — this document's terminal isn't running",
            comment: "Composer failure when the target terminal's process has exited"
        )
        TerminalAccessibilityAnnouncer.announce(reason)
        return .failed(reason)
    }
}

/// Pins the document + resolved target a composer targets, captured when it
/// opens so a later tab switch can't retarget the send or focus restore.
private struct ComposerContext: Identifiable {
    let id = UUID()
    let documentID: DocumentPane.ID
    let targetPaneID: TerminalPane.ID
    let seed: String
}

struct DocumentNudgeSendBarID: Hashable {
    let documentID: DocumentPane.ID
    let shellActivity: ShellActivity?
    let agentKind: AgentKind?
    let agentState: AgentState?

    init(documentID: DocumentPane.ID, target: TerminalPane?) {
        self.documentID = documentID
        shellActivity = target?.shellActivity
        agentKind = target?.agentKind
        agentState = target?.agentState
    }
}

private enum DocumentPaneMode {
    case document
    case files
}
