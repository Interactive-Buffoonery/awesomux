import AppKit
import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import SwiftUI
import os

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

    /// Opens the multiline composer for this document. Hosted by the enclosing
    /// group (above this bar's shell-activity-keyed identity) so an in-flight
    /// draft survives the bar being torn down and rebuilt when the target pane's
    /// shell activity flips.
    let onCompose: () -> Void

    /// Branch-diff file-section keys in document order, and this tab's folded
    /// set — the footer's Collapse All / Expand All writes the whole set back
    /// through `onSetCollapsedSections`. Empty on every other document kind.
    var sectionKeys: [String] = []
    var collapsedSections: Set<String> = []
    var onSetCollapsedSections: (Set<String>) -> Void = { _ in }

    /// Whether the last nudge attempt found no live surface — shown briefly so the
    /// user knows the action failed rather than silently no-oping.
    @State private var nudgeFailed = false
    /// Why the last Resume click failed, kept typed rather than collapsed into
    /// `nudgeFailed`. Six reasons share one Boolean otherwise, and the button's
    /// generic "this document's terminal isn't running" is the wrong sentence
    /// for five of them (review finding). Unlike the nudge flash, a typed
    /// denial PERSISTS: it names world state the user can act on, and the
    /// caption and accessibility label both read it until the verdict changes
    /// or the next attempt starts.
    @State private var resumeFailure: AgentTranscriptResumeUnavailableReason?
    /// A Resume attempt is awaiting its session-log probe. Drives the button's
    /// disabled state; the send itself is guarded in
    /// `AgentTranscriptResumeStaging`, which also sees the menu command.
    @State private var resumeInFlight = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Same convention as TerminalPaneView/SidebarSessionTile: read settings
    // through the environment-injected store, not `runtime`'s provider-closure
    // indirection, so enabling an integration recomputes `body` immediately
    // instead of waiting on an unrelated render (CodeRabbit finding).
    @Environment(AppSettingsStore.self) private var appSettingsStore
    @Environment(\.branchChangesRefresh) private var branchChangesRefresh
    /// Optional on purpose: the terminal panels host this bar from their own
    /// environment roots, which do not carry the app's coordinator. A missing
    /// coordinator means no busy state, never a crash.
    @Environment(BranchChangesCoordinator.self) private var branchChangesCoordinator: BranchChangesCoordinator?
    /// Bridges the gap between the click and the coordinator's set updating, so
    /// a double-click cannot start two runs. Cleared in the refresh completion.
    @State private var refreshRequested = false

    /// INT-569 field diagnostics: the one line that says why a send bar is
    /// disabled. Each individual probe already names its own guard, but nothing
    /// logged the resolved verdict, so a denial whose probes all pass was
    /// invisible.
    private nonisolated static let nudgeGateLogger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "DocumentNudgeGate"
    )

    private var nudgeResolution: DocumentNudgeTargetResolution {
        let resolved = resolvedNudgeTarget
        switch resolved {
        case .available(let target):
            Self.nudgeGateLogger.debug(
                "nudge verdict: document \(pane.id.uuidString, privacy: .public) AVAILABLE via pane \(target.id.uuidString, privacy: .public) kind \(String(describing: target.agentKind), privacy: .public)"
            )
        case .unavailable(let reason):
            // Identity only — the observed `p_comm` is logged by
            // `GhosttyRuntime.foregroundComm(in:)`, which the resolution above
            // already called. Re-probing here would issue a second live
            // process syscall on every render of a disabled send bar.
            //
            // The target lookup is a recursive layout walk, so it goes INSIDE
            // the interpolation: `os_log` arguments are autoclosures and cost
            // nothing when debug logging is off, but a `let` above the call
            // would run on every render of every disabled send bar in every
            // build (review finding). One helper, so it walks once, not once
            // per field.
            Self.nudgeGateLogger.debug(
                "nudge verdict: document \(pane.id.uuidString, privacy: .public) DENIED \(String(describing: reason), privacy: .public); \(Self.deniedTargetDescription(session.layout, pane.id), privacy: .public)"
            )
        }
        return resolved
    }

    /// One layout walk, rendered lazily from inside the log interpolation.
    private static func deniedTargetDescription(
        _ layout: TerminalPaneLayout,
        _ documentID: DocumentPane.ID
    ) -> String {
        guard let target = layout.documentSendTarget(for: documentID) else {
            return "target pane none"
        }
        return
            "target pane \(target.id.uuidString) kind \(target.agentKind) state \(target.agentState)"
    }

    private var resolvedNudgeTarget: DocumentNudgeTargetResolution {
        let integrations = appSettingsStore.agentIntegrations.value
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
                case .shell, .generic: false
                }
            },
            agentBinaryPath: { kind in
                switch kind {
                case .claudeCode: integrations.claudeCode.binaryPath
                case .codex: integrations.codex.binaryPath
                case .openCode: integrations.openCode.binaryPath
                case .pi: integrations.pi.binaryPath
                case .grok: integrations.grok.binaryPath
                case .shell, .generic: nil
                }
            },
            foregroundComm: { runtime.foregroundComm(in: $0) },
            foregroundGeneration: { runtime.foregroundGeneration(in: $0) },
            verifiedWaitingForegroundGeneration: { runtime.verifiedWaitingForegroundGeneration(in: $0) }
        )
    }

    static func resolveNudgeTarget(
        in layout: TerminalPaneLayout,
        for documentID: DocumentPane.ID,
        isIntegrationEnabled: (AgentKind) -> Bool,
        agentBinaryPath: (AgentKind) -> String? = { _ in nil },
        foregroundComm: (TerminalPane.ID) -> String?,
        foregroundGeneration: (TerminalPane.ID) -> AgentForegroundIncarnation? = { _ in nil },
        verifiedWaitingForegroundGeneration: (TerminalPane.ID) -> AgentForegroundIncarnation? = { _ in nil }
    ) -> DocumentNudgeTargetResolution {
        let resolution = layout.documentNudgeTarget(for: documentID)
        guard case .available(let target) = resolution else { return resolution }
        // One live probe per resolution: the SSH safety check and the prompt
        // gate both read the same observed foreground process name. Absent
        // evidence fails closed before either check.
        guard let observedComm = foregroundComm(target.id) else {
            return .unavailable(.localTerminalUnverified)
        }
        // Normalized like every other name comparison in this chain. `ssh` is
        // denied either way (it is on the gate's non-agent list), but this
        // branch owns the reason the USER reads, and an unnormalized compare
        // would show them the generic denial instead of "exit SSH".
        if AgentPromptGate.normalizedForegroundName(observedComm) == "ssh" {
            return .unavailable(.foregroundSSH)
        }
        // Verified-agent-prompt gate (INT-569).
        switch AgentPromptGate.verdict(
            agentKind: target.agentKind,
            agentState: target.agentState,
            isIntegrationEnabled: isIntegrationEnabled,
            observedForegroundCommand: observedComm,
            verifiedWaitingForegroundGeneration: verifiedWaitingForegroundGeneration(target.id),
            observedForegroundGeneration: foregroundGeneration(target.id),
            configuredBinaryCandidate: {
                guard let path = agentBinaryPath(target.agentKind), !path.isEmpty else {
                    return nil
                }
                // `p_comm` names the RESOLVED file: a `claude` symlink to
                // `versions/2.1.214` observes as "2.1.214", so resolve the
                // configured path before taking its basename.
                return URL(fileURLWithPath: path).resolvingSymlinksInPath().lastPathComponent
            }
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
        return Self.unavailableDescription(for: reason)
    }

    /// Localized reason a document can't be sent. Shared with the composer sheet
    /// (hosted above the send bar's churning identity) so both surfaces speak the
    /// same language for an unavailable target.
    static func unavailableDescription(for reason: DocumentNudgeUnavailableReason) -> String {
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
                localized: "Enable the \(kind.displayName) integration in Settings to send",
                comment: "Unavailable reason when the target agent's integration is disabled in settings"
            )
        case .agentNotReceptive(let kind):
            return String(
                localized: "\(kind.displayName) isn't waiting for input yet",
                comment: "Unavailable reason when the target agent is not currently waiting at its prompt"
            )
        }
    }

    /// Names the agent whenever one was identified — the verified target AND
    /// the agent-specific denials (not receptive, integration disabled): a
    /// disabled "Send to Claude" with the caption explaining why beats an
    /// anonymous button when the gate knows who is there. Generic "Send to
    /// Agent" only when no agent was identified, so the wording still never
    /// claims an agent that wasn't detected. Enabled state and caption come
    /// from the same resolution (one-verdict invariant).
    static func sendButtonTitle(
        for resolution: DocumentNudgeTargetResolution
    ) -> String {
        let namedKind: AgentKind?
        switch resolution {
        case .available(let target):
            namedKind = target.agentKind
        case .unavailable(.agentNotReceptive(let kind)),
            .unavailable(.agentIntegrationDisabled(let kind)):
            namedKind = kind
        case .unavailable:
            namedKind = nil
        }
        guard let namedKind else {
            return String(
                localized: "Send to Agent",
                comment: "Generic send-bar button title when no agent was identified in the target terminal"
            )
        }
        return String(
            localized: "Send to \(namedKind.displayName)",
            comment: "Send-bar button title naming the agent identified in the target terminal"
        )
    }

    // MARK: - Branch changes footer

    /// Refresh re-runs the comparison for the terminal this tab was generated
    /// from, which is not necessarily the active pane. The structural
    /// resolution is used deliberately — unlike Send to Agent, re-running git
    /// needs a live local terminal, not a receptive agent.
    private var branchChangesControls: some View {
        // One layout walk per render; the busy check reuses the same resolution.
        let target = session.layout.documentNudgeTarget(for: pane.id)
        let verdict = BranchChangesRefreshPolicy.verdict(
            target: target,
            inFlight: refreshRequested || isRefreshing(target)
        )
        let unavailable: String? = {
            if case .unavailable(let caption) = verdict { return caption }
            return nil
        }()
        // One row of equal-height buttons with the caption under both: the
        // caption belongs to the row, not to Refresh, or Collapse All ends up
        // vertically centred against a two-line neighbour.
        return VStack(spacing: 3) {
            HStack(spacing: 8) {
                // Only Refresh needs the app's command; Collapse All needs
                // nothing from the environment, so a hosting root without the
                // action (the terminal panels) keeps today's label and still
                // gets the folds.
                if branchChangesRefresh == nil {
                    readOnlyGeneratedDocumentLabel
                } else {
                    SendToAgentButton(
                        purpose: .refreshBranchChanges,
                        title: String(
                            localized: "Refresh",
                            comment:
                                "Send-bar button title on a branch changes tab that re-runs the comparison"
                        ),
                        failed: false,
                        isBusy: verdict == .busy,
                        unavailableDescription: unavailable,
                        action: refresh
                    )
                    .frame(height: 28)
                }
                if !sectionKeys.isEmpty {
                    // After a refresh adds one file, this reads "Collapse All"
                    // again while the rest stay folded. Cosmetic and
                    // self-correcting on the next press.
                    let allCollapsed = Set(sectionKeys).isSubset(of: collapsedSections)
                    Button {
                        onSetCollapsedSections(allCollapsed ? [] : Set(sectionKeys))
                    } label: {
                        Text(
                            allCollapsed
                                ? String(
                                    localized: "Expand All",
                                    comment:
                                        "Send-bar button on a branch changes tab that unfolds every file section"
                                )
                                : String(
                                    localized: "Collapse All",
                                    comment:
                                        "Send-bar button on a branch changes tab that folds every file section"
                                )
                        )
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.aw.mauve)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        // Same plate as `SendToAgentButton` (mauve at 0.15 over a
                        // 1pt mauve rule, 6pt corners), so the row reads as one
                        // control family rather than a system button beside a
                        // custom one.
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.aw.mauve.opacity(0.15))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.aw.mauve, lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            if branchChangesRefresh != nil {
                Text(
                    unavailable
                        ?? String(
                            localized: "Read-only generated document",
                            comment: "Footer label on a generated document tab; also the caption under Refresh on a branch changes tab"
                        )
                )
                .font(.system(size: 11))
                .foregroundStyle(Color.aw.text2)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var readOnlyGeneratedDocumentLabel: some View {
        Label(
            String(
                localized: "Read-only generated document",
                comment: "Footer label on a generated document tab; also the caption under Refresh on a branch changes tab"
            ),
            systemImage: "lock"
        )
        .lineLimit(1)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.aw.text2)
        .frame(maxWidth: .infinity, minHeight: 28)
    }

    private func isRefreshing(_ resolution: DocumentNudgeTargetResolution) -> Bool {
        guard case .available(let target) = resolution,
            let branchChangesCoordinator
        else { return false }
        return branchChangesCoordinator.refreshingPaneIDs.contains(target.id)
    }

    private func refresh() {
        // Click time resolves afresh: the layout may have moved since the render.
        guard !refreshRequested,
            !isRefreshing(session.layout.documentNudgeTarget(for: pane.id)),
            let branchChangesRefresh,
            case .available(let target) = session.layout.documentNudgeTarget(for: pane.id)
        else { return }
        refreshRequested = true
        // The tab's own id travels with the run: if the user closes this tab
        // while git is still going, the completion must not resurrect it.
        branchChangesRefresh.run(target.id, pane.id) { refreshRequested = false }
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
            } else if let identity = pane.agentTranscriptIdentity {
                // Resume REPLACES Send on a transcript tab rather than sitting
                // beside it: a transcript is not editable, so it can hold no
                // review comments, and Send to Agent would have nothing to send.
                resumeControl(identity: identity)
            } else if pane.generatedDocumentKind == .branchChanges {
                branchChangesControls
            } else if pane.generatedDocumentKind != nil {
                readOnlyGeneratedDocumentLabel
            } else {
                // Resolve once per render: the resolution issues a live foreground
                // probe, and the title, the unavailable description, and the
                // caption all derive from the same verdict (one-verdict invariant).
                let resolution = nudgeResolution
                let unavailableDescription = sendUnavailableDescription(for: resolution)
                VStack(spacing: 3) {
                    SendToAgentButton(
                        title: Self.sendButtonTitle(for: resolution),
                        failed: nudgeFailed,
                        unavailableDescription: unavailableDescription,
                        action: requestCompose
                    )
                    .frame(height: 28)
                    if let unavailableDescription {
                        // Visible "why" for the disabled state. The button's
                        // accessibility label already speaks the same string,
                        // so the caption hides from VoiceOver to avoid a
                        // double announcement.
                        Text(unavailableDescription)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.aw.text2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity)
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
            guard !Task.isCancelled else { return }
            // A typed Resume denial must NOT share this flash: its reason is
            // world state (the log is gone, an agent took the terminal), and
            // both the caption and the button's accessibility label derive
            // from it. Persist it until the verdict changes or the next
            // attempt, so a VoiceOver user who missed the one-shot
            // announcement can still read why from the button itself.
            guard resumeFailure == nil else { return }
            nudgeFailed = false
        }
        // The typed Resume denial's lifetime: the reason it names is state of
        // the world, so it clears when that state changes (the verdict flips)
        // or when the next attempt starts, never on a timer. On a plain
        // document there is no Resume control and nothing to clear.
        .onChange(of: resumeVerdict) {
            guard pane.agentTranscriptIdentity != nil else { return }
            resumeFailure = nil
            nudgeFailed = false
        }
    }

    // MARK: - Resume

    /// The transcript tab's primary action: stage this session's resume command
    /// into the adjacent terminal, never submit it.
    @ViewBuilder
    private func resumeControl(identity: AgentTranscriptIdentity) -> some View {
        let verdict = resumeVerdict
        let unavailableDescription = Self.resumeUnavailableDescription(for: verdict)
        // A click-time failure has its own sentence, and the verdict that
        // produced the button is often still `.eligible` when it happens (the
        // log went missing, an agent took the foreground during the probe).
        // Shown as the caption so the reason is visible, not only spoken.
        let failureDescription = resumeFailure.map(Self.resumeUnavailableDescription(for:))
        let caption = unavailableDescription ?? failureDescription
        VStack(spacing: 3) {
            SendToAgentButton(
                purpose: .resumeSession,
                title: String(
                    localized: "Resume \(identity.agentKind.displayName)",
                    comment: "Send-bar button title on a transcript tab, naming the agent to resume"
                ),
                failed: nudgeFailed,
                failureDescription: failureDescription,
                isBusy: resumeInFlight,
                unavailableDescription: unavailableDescription,
                action: { stageResume(identity: identity) }
            )
            .frame(height: 28)
            if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.aw.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The cheap half of the policy — association, local execution, and the
    /// target's live foreground process.
    ///
    /// Deliberately does NOT probe the provider's session log: that is a
    /// directory walk, and this recomputes on every render of the bar. The
    /// log-still-exists check belongs at click time, in `stageResume`.
    private var resumeVerdict: AgentTranscriptResumeVerdict {
        let target = session.layout.documentNudgeTarget(for: pane.id)
        let observedComm: String? = {
            guard case .available(let resolved) = target else { return nil }
            return runtime.foregroundComm(in: resolved.id)
        }()
        return AgentTranscriptResumePolicy.verdict(
            target: target,
            observedForegroundCommand: observedComm,
            identity: pane.agentTranscriptIdentity
        )
    }

    static func resumeUnavailableDescription(
        for verdict: AgentTranscriptResumeVerdict
    ) -> String? {
        guard case .unavailable(let reason) = verdict else { return nil }
        return resumeUnavailableDescription(for: reason)
    }

    static func resumeUnavailableDescription(
        for reason: AgentTranscriptResumeUnavailableReason
    ) -> String {
        switch reason {
        case .terminalUnavailable:
            return String(
                localized: "This transcript's terminal isn't available",
                comment: "Unavailable reason for resuming a session when its associated terminal is gone"
            )
        case .requiresLocalTerminal:
            return String(
                localized: "Sessions can only be resumed in a local terminal",
                comment: "Unavailable reason for resuming a session into a terminal that runs over SSH"
            )
        case .foregroundUnverified:
            return String(
                localized: "Couldn't verify what's running in this transcript's terminal",
                comment: "Unavailable reason for resuming a session when foreground process evidence is unavailable"
            )
        case .agentRunning:
            return String(
                localized: "This session is still running and can’t be resumed",
                comment: "Unavailable reason for resuming a session while an agent still holds the terminal"
            )
        case .foregroundBusy:
            return String(
                localized: "Resume is available at a shell prompt — this terminal is busy",
                comment: "Unavailable reason for resuming a session while a non-shell program holds the terminal"
            )
        case .transcriptMissing:
            return String(
                localized: "This session's log is no longer available, so it can't be resumed",
                comment: "Unavailable reason for resuming a session whose provider log has been deleted"
            )
        case .noResumeSyntax(let kind):
            return String(
                localized: "awesoMux doesn't know how to resume a \(kind.displayName) session",
                comment: "Unavailable reason for resuming a provider awesoMux has no resume command for"
            )
        case .noTranscriptSelected:
            return String(
                localized: "Select an agent transcript tab first — Resume acts on the transcript you're reading",
                comment:
                    "Unavailable reason for resuming when the selected document tab is not an agent transcript"
            )
        }
    }

    /// Stages `claude --resume`, `codex resume`, or `pi --session` into the
    /// adjacent terminal as an editable draft.
    ///
    /// Never auto-submitted, matching the shipped Send to Agent posture: the
    /// user presses Return.
    ///
    /// The ladder itself — eligibility, the detached session-log probe, the
    /// foreground recheck, and the separator that keeps the staged line off the
    /// end of a half-typed command — lives in `AgentTranscriptResumeStaging`,
    /// because the menu/palette command runs the identical sequence and this
    /// button cannot be reached by keyboard at all.
    private func stageResume(identity: AgentTranscriptIdentity) {
        guard !resumeInFlight else { return }
        resumeInFlight = true
        resumeFailure = nil
        nudgeFailed = false
        TerminalAccessibilityAnnouncer.announce(
            String(
                localized: "Checking this session's log",
                comment: "VoiceOver announcement when Resume starts probing whether the session log still exists"
            )
        )
        Task { @MainActor in
            let outcome = await AgentTranscriptResumeStaging.stage(
                identity: identity,
                documentID: pane.id,
                layout: session.layout,
                integrations: appSettingsStore.agentIntegrations.value,
                foregroundComm: { runtime.foregroundComm(in: $0) },
                sendText: { runtime.sendText($0, toPane: $1) }
            )
            resumeInFlight = false
            switch outcome {
            case .staged:
                nudgeFailed = false
                TerminalAccessibilityAnnouncer.announce(
                    String(
                        localized: "Pasted into this transcript's terminal — press Return there to resume",
                        comment: "VoiceOver announcement after staging a resume command into the associated terminal"
                    ),
                    // See the matching call in `AwesoMuxApp`: at `.medium` the
                    // terminal's own `.valueChanged` for the newly staged text
                    // preempted this, so the user heard the command but not
                    // that it was staged rather than run.
                    priority: .high
                )
            case .alreadyStaging:
                // The menu/palette command owns this document's send.
                // Reporting a failure the user did not cause would be a lie —
                // but staying silent would be this click's version of a dead
                // command: this route's local busy state never saw the other
                // route's probe, so without speech nothing here distinguishes
                // "already checking" from an ignored click. Same sentence and
                // priority as the app-level route.
                TerminalAccessibilityAnnouncer.announceResumeAlreadyChecking()
            case .unavailable(let reason):
                reportResumeUnavailable(reason)
            }
        }
    }

    private func reportResumeUnavailable(_ reason: AgentTranscriptResumeUnavailableReason) {
        resumeFailure = reason
        nudgeFailed = true
        TerminalAccessibilityAnnouncer.announce(Self.resumeUnavailableDescription(for: reason))
    }

    // MARK: - Composer

    /// Opens the composer (hosted by the enclosing group) when the target is
    /// eligible; otherwise reports the reason on the button rather than opening a
    /// composer that can't send. The composer replaces the old one-shot send: the
    /// user revises or extends the review nudge before staging it.
    private func requestCompose() {
        let resolution = nudgeResolution
        guard case .available = resolution else {
            reportNudgeUnavailable(resolution)
            return
        }
        onCompose()
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
    /// What this instance of the bar's one call-to-action does. Only the glyph
    /// and the non-visual copy differ, so the two purposes share the button
    /// rather than forking a second `NSViewRepresentable` with the same
    /// focus-safety, layer-color, and inline-attachment reasoning to maintain.
    enum Purpose {
        case sendToAgent
        case resumeSession
        case refreshBranchChanges

        var symbolName: String {
            switch self {
            case .sendToAgent: "paperplane.fill"
            case .resumeSession: "play.fill"
            case .refreshBranchChanges: "arrow.clockwise"
            }
        }

        /// Spoken and tooltip copy for the enabled state.
        var affordanceDescription: String {
            switch self {
            case .sendToAgent:
                String(
                    localized: "sends your review comments to this document's terminal",
                    comment: "Accessibility/tooltip phrase describing what the document send button does"
                )
            case .resumeSession:
                String(
                    localized:
                        "pastes this session's resume command into the terminal without running it",
                    comment: "Accessibility/tooltip phrase describing what the transcript resume button does"
                )
            case .refreshBranchChanges:
                String(
                    localized: "re-runs the branch comparison for this tab's terminal",
                    comment: "Accessibility/tooltip phrase describing what the branch changes refresh button does"
                )
            }
        }

        /// Spoken copy while an attempt is in flight. Per purpose: the busy
        /// state is the one label that names what the button is actually
        /// waiting on, so a shared sentence speaks the wrong thing on every
        /// purpose but the one it was written for.
        var busyDescription: String {
            switch self {
            case .sendToAgent:
                // Send is never busy today — `isBusy` is left at its default at
                // that call site, because the compose sheet, not the button,
                // owns the wait. Kept exhaustive rather than fatal so a future
                // busy Send speaks something honest instead of trapping.
                String(
                    localized: "sending",
                    comment: "Accessibility phrase while the document send button is mid-send"
                )
            case .resumeSession:
                String(
                    localized: "checking this session's log",
                    comment: "Accessibility phrase while a Resume attempt probes the provider's session log"
                )
            case .refreshBranchChanges:
                String(
                    localized: "re-running the comparison",
                    comment: "Accessibility phrase while a branch changes Refresh is re-running git"
                )
            }
        }
    }

    var purpose: Purpose = .sendToAgent
    let title: String
    let failed: Bool
    /// The typed reason the last attempt failed, when the caller has one.
    /// Without it a failure speaks the generic "terminal isn't running", which
    /// is the wrong sentence for most Resume denials.
    var failureDescription: String? = nil
    /// An attempt is in flight. Disables the button so a second click cannot
    /// stage the payload twice while the first is still probing.
    var isBusy: Bool = false
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
        nsView.isEnabled = isEnabled && !isBusy
        let showsFailure = failed && isEnabled
        let accent = NSColor(isEnabled ? (showsFailure ? Color.aw.peach : Color.aw.mauve) : Color.aw.text2)
        nsView.layer?.backgroundColor = accent.withAlphaComponent(0.15).cgColor
        nsView.layer?.borderColor = accent.cgColor
        // The failed state also swaps the glyph (paperplane → warning triangle):
        // the hue shift alone is a color-only signal that colorblind users can't
        // perceive (WCAG 1.4.1), and this button can't be keyboard-focused for
        // the tooltip.
        nsView.attributedTitle = Self.makeTitle(
            title,
            color: accent,
            symbolName: showsFailure ? "exclamationmark.triangle.fill" : purpose.symbolName
        )
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
                        localized: "\(title) — unavailable: \(failureDescription ?? Self.genericFailureDescription)",
                        comment: "Accessibility label for the send button after an attempt failed, naming the reason"
                    )
                    : isBusy
                        ? String(
                            localized: "\(title) — \(purpose.busyDescription)",
                            comment: "Accessibility label for the send bar button while its attempt is in flight"
                        )
                        : String(
                            localized: "\(title) — \(purpose.affordanceDescription)",
                            comment: "Accessibility label for the document send bar's call-to-action button"
                        ))
        )
        nsView.toolTip =
            unavailableDescription
            ?? (failed
                ? (failureDescription ?? Self.genericFailureTooltip)
                : String(
                    localized: "\(title) — \(purpose.affordanceDescription)",
                    comment: "Tooltip for the document send bar's call-to-action button"
                ))
    }

    /// The Send path has no typed reason to offer, so it keeps the original
    /// copy; Resume passes its own and never reaches these.
    private static var genericFailureDescription: String {
        String(
            localized: "this document's terminal isn't running",
            comment: "Fallback reason phrase for the send button when no typed failure reason is available"
        )
    }

    private static var genericFailureTooltip: String {
        String(
            localized: "This document's terminal isn't available — reopen the document from a running terminal to reconnect",
            comment: "Tooltip for the send button when its terminal is gone"
        )
    }

    /// Builds a centered "✈ Send to Agent" title with the glyph as an inline,
    /// vertically-centered attachment so it sits right beside the text, both
    /// tinted `color`. The failed state swaps the paperplane for a warning
    /// triangle so failure has a shape, not just a hue.
    private static func makeTitle(
        _ text: String,
        color: NSColor,
        symbolName: String
    ) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let result = NSMutableAttributedString()

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
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

// MARK: - TranscriptReloadSelectionDeferral

struct TranscriptReloadSelectionDeferral {
    private(set) var hasPendingReload = false

    /// Repeated source replacements that cannot preserve the selected
    /// characters collapse into one pending catch-up.
    mutating func deferReload() {
        hasPendingReload = true
    }

    /// Avoids repeating cache reads and renders after an incompatible source
    /// replacement has already been deferred for the current selection.
    mutating func shouldStartWatcherReload(hasSelection: Bool) -> Bool {
        guard hasPendingReload else { return true }
        guard !hasSelection else { return false }
        hasPendingReload = false
        return true
    }

    /// Consumes the one pending catch-up when selection becomes empty.
    mutating func resumeAfterSelectionChange(hasSelection: Bool) -> Bool {
        guard !hasSelection, hasPendingReload else { return false }
        hasPendingReload = false
        return true
    }
}

// MARK: - DocumentPaneView

/// Renders a `DocumentPane` — validates the URL, loads the markdown file, and
/// displays it using `MarkdownTextView` (Task 3+). The `MarkdownView` fallback
/// this used to name is gone: `.loaded` never arrives without a rendered
/// document, so the branch was unreachable.
///
/// Load lifecycle (PR2 Task 3: read-once on appear, no live reload):
///   1. `DocumentURLValidator` checks scheme, extension, and size.
///   2. `DocumentLoader` reads the file and returns its source.
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
    // Internal (not private) so DocumentRevisionMonitor's background watchers
    // share the same self-write suppression the mounted pane records into.
    @MainActor static var selfWriteRegistry = MarkdownSelfWriteRegistry()

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
    /// Produces the provider handoff state for annotation popovers on demand.
    /// Invoked only when a comment popover is about to open: the projection
    /// issues a live foreground probe, so it must not run per render. Nil
    /// (callers that never pass a provider) keeps the section hidden.
    var annotationHandoffProvider: (() -> AnnotationHandoffPresentation)?
    /// Opens the existing composer with the clicked annotation prioritized.
    /// The rendered document supplies its current open-id projection so the
    /// handoff does not depend on session-memory timing.
    var onSendAnnotation: (String, [String]) -> Void = { _, _ in }
    /// Surfaces the coordinator's scroll-anchor capture to the group view so it
    /// can snapshot the outgoing tab's position on a tab switch (INT-748 PR2).
    var onRegisterScrollAnchorCapture: ((@escaping @MainActor () -> Int?) -> Void)?
    /// Collapsed branch-diff section keys, owned by the group's tab memory.
    /// The index itself is NOT an input: this view owns it (`localSectionIndex`),
    /// computed from the document it actually renders, so a group-held index
    /// that lags a render can never shadow the current one.
    var collapsedSections: Set<String> = []
    var onSectionToggled: ((String) -> Void)?
    /// Saves Copy Mode in the parent tab memory so tab and Files round trips
    /// preserve the user's explicit mode choice.
    var onCopyModeChanged: (Bool) -> Void

    /// Task 6: terminal background propagated by TerminalPaneView so the highlight
    /// contrast is measured against the actual painted surface, not the app chrome.
    @Environment(\.terminalBackgroundColor) private var terminalBackgroundColor

    @State private var loadResult: DocumentLoader.LoadResult? = nil
    @State private var renderedDoc: RenderedDocument? = nil
    /// Task 6 reads this to drive fold state; declared here since it comes from
    /// the same render pass as `renderedDoc`. `nil` on branch-changes tabs
    /// whose load rejected or errored, and always nil off that pane kind.
    @State private var localSectionIndex: BranchDiffSectionIndex? = nil
    /// True while the file on disk is over the size cap and the last whole
    /// render is being held on screen behind `DocumentOversizeBanner`.
    ///
    /// Seeded at init from `DocumentOversizePolicy.oversizePaths` and written
    /// back by the load task, so it survives a remount. That matters for the
    /// settle window, which is only reachable while this is true: a tab switch
    /// during a non-atomic rewrite would otherwise remount into a banner-free
    /// state and apply — and cache — the writer's half-finished prefix.
    @State private var showsOversizeBanner: Bool
    /// The banner established by the last failed refresh of a remote snapshot.
    /// Deliberately separate from `showsOversizeBanner`, not a
    /// second way to set it: the load task clears that one on every successful
    /// local read, and this pane's local cache file always reads fine — it is
    /// only written when the payload fits. Sharing one flag would have the
    /// first reload erase the banner.
    @State private var remoteStaleBannerKind: DocumentOversizeBanner.Kind?
    @State private var selectedSourceSpan: Range<Int>? = nil
    // INT-580 annotation surface state is per-pane and deliberately unpersisted.
    @State private var hideResolved = false
    /// A copy-friendly presentation for documents whose review is complete.
    /// Text remains selectable, but resolved markup and comment creation are
    /// suppressed until the user returns to Review Mode.
    @State private var isCopyMode = false
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
    @State private var transcriptReloadSelectionDeferral = TranscriptReloadSelectionDeferral()
    // Written during MarkdownTextView's update pass — safe ONLY while no
    // `body` ever reads it; keep reads inside event closures.
    @State private var scrollAnchorCapture: (@MainActor () -> Int?)? = nil
    @State private var pendingScrollAnchor: Int? = nil
    /// Latches the one live-refresh announcement this mount is allowed (#494).
    /// `@State` behind the view's `.id(fileURL)` gives it exactly the lifetime
    /// the rule needs: it resets on a remount and on a transcript-identity
    /// change (the cache slot is keyed by agent kind and session id, so a
    /// different session is a different path), and it does NOT reset on a
    /// window-activation flip, which restarts the refresh loop but is not a new
    /// document to warn the reader about.
    @State private var announcedLiveTranscriptRefresh = false

    /// `cachedRender` seeds `loadResult`/`renderedDoc` so a tab the user
    /// switches back to shows its content immediately instead of a spinner —
    /// the load task still re-reads the file (the watcher was off while the tab
    /// was hidden) and swaps in any changes. A successful cached seed has empty
    /// blocks and no file snapshot; `renderedDoc` paints immediately while
    /// snapshot-dependent edits wait for that reload. `initialScrollAnchor`
    /// seeds `pendingScrollAnchor` so the first render restores the tab's last
    /// scroll position; it's a `State` seed (not a fallback read on every pass)
    /// so the reset paths that clear the pending anchor stay authoritative.
    @MainActor
    init(
        pane: DocumentPane,
        cachedRender: DocumentTabMemory.Render? = nil,
        initialScrollAnchor: Int? = nil,
        initialCopyMode: Bool = false,
        onCopyModeChanged: @escaping (Bool) -> Void = { _ in },
        onCommentCountChanged: @escaping (Int) -> Void = { _ in },
        onRenderCompleted: ((DocumentTabMemory.Render) -> Void)? = nil,
        onOpenDocumentLink: ((URL) -> Void)? = nil,
        onRevision: @escaping (LineDiffCount.ExternalEdit) -> Void = { _ in },
        annotationHandoffProvider: (() -> AnnotationHandoffPresentation)? = nil,
        onSendAnnotation: @escaping (String, [String]) -> Void = { _, _ in },
        onRegisterScrollAnchorCapture: ((@escaping @MainActor () -> Int?) -> Void)? = nil,
        collapsedSections: Set<String> = [],
        onSectionToggled: ((String) -> Void)? = nil
    ) {
        self.pane = pane
        self.onCommentCountChanged = onCommentCountChanged
        self.onRenderCompleted = onRenderCompleted
        self.onOpenDocumentLink = onOpenDocumentLink
        self.onRevision = onRevision
        self.annotationHandoffProvider = annotationHandoffProvider
        self.onSendAnnotation = onSendAnnotation
        self.onRegisterScrollAnchorCapture = onRegisterScrollAnchorCapture
        self.collapsedSections = collapsedSections
        self.onSectionToggled = onSectionToggled
        self.onCopyModeChanged = onCopyModeChanged
        _loadResult = State(initialValue: cachedRender?.loadResult)
        _renderedDoc = State(initialValue: cachedRender?.renderedDoc)
        _localSectionIndex = State(initialValue: cachedRender?.sectionIndex)
        _pendingScrollAnchor = State(initialValue: initialScrollAnchor)
        _isCopyMode = State(initialValue: initialCopyMode)
        _showsOversizeBanner = State(
            initialValue: DocumentOversizePolicy.isOversize(
                path: pane.fileURL.standardizedFileURL.path))
        _remoteStaleBannerKind = State(
            initialValue: RemoteSnapshotStalePolicy.bannerKind(
                path: pane.fileURL.standardizedFileURL.path))
    }

    // MARK: - Derived

    private var highlightColor: NSColor {
        HighlightContrast.color(forTerminalBackground: NSColor(terminalBackgroundColor))
    }

    private var markdownTextColor: NSColor {
        MarkdownAttributedStringBuilder.textColor(forTerminalBackground: NSColor(terminalBackgroundColor))
    }

    /// The snapshot the annotation surface may commit against.
    ///
    /// While the oversize banner is up, the retained `.loaded` result
    /// describes bytes the disk no longer has. Withholding the snapshot here
    /// is the single chokepoint that takes the whole surface read-only:
    /// `annotationsInteractive`, the pill and selection handlers, the context
    /// menu, the annotation bar, and the note sheet all already gate on a
    /// non-nil snapshot. Leaving them live would make every save commit
    /// against a stale observation, conflict, reload, land back on the size
    /// rejection, and invite the user to try again — forever.
    ///
    /// Static and pure so the rule is checkable without hosting the view.
    static func editableSnapshot(
        _ snapshot: MarkdownDocumentSnapshot?,
        isBannerShowing: Bool
    ) -> MarkdownDocumentSnapshot? {
        isBannerShowing ? nil : snapshot
    }

    /// Whether a reload must report its render to the tab cache: yes when
    /// either side is missing (an error clears cached content; a first render
    /// seeds it) or the on-disk source differs from what was rendered.
    ///
    /// Compares UTF-8 bytes (`utf8.elementsEqual`), matching `DocumentLoader`,
    /// which makes the same byte-exact comparison when deciding whether to
    /// rebuild. Two notions of equality on one path would strand the cache: a
    /// document rewritten between normalization forms (NFD ↔ NFC) renders
    /// identically, but its bytes change — `DocumentLoader` correctly rebuilds,
    /// while a canonically-equivalent `String !=` here would suppress the
    /// report and leave every remount reseeding the stale render forever. The
    /// walk is O(n), bounded by the 2 MiB document size cap
    /// (`DocumentURLValidator.maxFileSizeBytes`). A digest computed at load
    /// time would give the fast comparison safely; that's a follow-up, not
    /// something to hand-roll here.
    ///
    /// Static and pure so the rule is checkable without hosting the view.
    static func sourceChanged(_ doc: RenderedDocument?, _ priorDoc: RenderedDocument?) -> Bool {
        switch (doc?.source, priorDoc?.source) {
        case let (source?, priorSource?):
            return !source.utf8.elementsEqual(priorSource.utf8)
        default:
            return true
        }
    }

    private var currentSnapshot: MarkdownDocumentSnapshot? {
        guard case let .loaded(_, snapshot) = loadResult else { return nil }
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
                case let .loaded(_, snapshot):
                    loadedView(snapshot: snapshot)

                case let .rejected(reason):
                    errorView(message: Self.rejectionMessage(for: reason, pane: pane))

                case let .readError(message):
                    errorView(message: Self.readErrorMessage(message, pane: pane))
                }
            } else {
                ProgressView()
                    .accessibilityLabel("Loading document")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: isCopyMode) { _, copying in
            onCopyModeChanged(copying)
            if copying {
                nsPopover?.close()
                nsPopover = nil
            }
            TerminalAccessibilityAnnouncer.announce(
                copying
                    ? String(
                        localized: "Copy mode enabled. Selecting text will not create comments.",
                        comment: "VoiceOver announcement when a Markdown document enters copy mode")
                    : String(
                        localized: "Review mode enabled. Selecting text can create comments.",
                        comment: "VoiceOver announcement when a Markdown document leaves copy mode")
            )
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: RemoteSnapshotStalePolicy.didChangeNotification)
        ) { notification in
            guard let change = notification.object as? RemoteSnapshotStalePolicy.Change,
                change.path == pane.fileURL.standardizedFileURL.path
            else { return }
            remoteStaleBannerKind = change.kind
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
        .onChange(of: pane.agentTranscriptIdentity != nil) { _, _ in
            // A tab can become a transcript after it mounts: the reducer
            // backfills `agentTranscriptIdentity` onto the pane that already
            // holds this file URL, and the URL is this view's identity, so
            // nothing remounts and `onAppear` never fires again. The coalescing
            // mode below is chosen once when the watcher starts, so without
            // this restart such a tab keeps the debounced watcher it was given
            // as an ordinary document — which is exactly the starvation live
            // refresh exists to remove, on the one tab that just became
            // eligible for it.
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
                            return .loaded(source: source, snapshot: $0)
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

            // `guardedWrite`'s `.observedConflict` branch parks on this
            // generation, and the popover it is blocking is
            // `.applicationDefined` (non-transient) while submitting — so a
            // missed completion doesn't merely leak a task, it leaves the user
            // an undismissable popover. `defer` so no branch added below can
            // ever skip it, registered above the settle sleep so "every path
            // out of the task runs it" is true of the whole body rather than
            // only the part after the sleep.
            defer { reloadCompletion.complete(reloadTaskID.generation) }

            let decision = DocumentOversizePolicy.decide(
                result: result,
                hasPriorRender: renderedDoc != nil,
                isBannerShowing: showsOversizeBanner
            )
            if decision == .settle {
                // Hold a recovered read before promoting it to the protected
                // render. If the file crosses back over the cap inside the
                // window, the watcher bumps the generation, this task is
                // cancelled at the guard below, and what stays on screen is
                // still the last WHOLE render rather than a half-written
                // prefix that happened to be under cap when we looked.
                await DocumentOversizePolicy.settleWait()
                guard !Task.isCancelled,
                    reloadTaskID.fileURL == pane.fileURL,
                    reloadTaskID.generation == reloadGeneration
                else { return }
            }
            let path = pane.fileURL.standardizedFileURL.path
            guard decision != .retainRender else {
                // The bytes are still on disk and still real; only this viewer
                // declines to render them. Keep the last whole render — and
                // the reader's place in it — mounted under a banner instead of
                // replacing it with an error page.
                DocumentOversizePolicy.noteOversize(true, path: path)
                if !showsOversizeBanner {
                    showsOversizeBanner = true
                    // The banner is the only accessible signal: the rendered
                    // body is a single `.staticText` element, so nothing about
                    // the change is discoverable from the document itself.
                    //
                    // `.high` like every other state transition here
                    // (`announceWaitingForInput`, the workspace-closed and
                    // settings-error announcements): the trigger is an agent
                    // writing to the file, which is exactly when the sibling
                    // terminal is loudest, and `.medium` is queued and
                    // preemptible.
                    TerminalAccessibilityAnnouncer.announce(
                        DocumentOversizeBanner.accessibilityLabel(fileName: pane.title),
                        priority: .high
                    )
                }
                return
            }
            DocumentOversizePolicy.noteOversize(false, path: path)
            showsOversizeBanner = false
            renderedDoc = doc
            if isCopyMode,
                let doc,
                !DocumentCopyModePolicy.isAvailable(
                    in: DocumentAnnotationProjection(document: doc))
            {
                isCopyMode = false
            }
            loadResult = result
            // The watcher deliberately retains the captured scroll anchor for
            // every nil snapshot, because the over-cap case keeps the mounted
            // render and the reader's place in it. Every other nil — deleted,
            // unreadable, wrong extension, non-UTF-8 — lands here instead and
            // tears the document down to the error page, where the anchor is a
            // byte offset into a document that no longer exists. Left set it
            // survives in `@State`, and the next time the file comes back with
            // different content `MarkdownTextView` scrolls to it. Cleared here
            // rather than at the watcher so every caller is covered at once.
            switch result {
            case .loaded: break
            case .rejected, .readError: pendingScrollAnchor = nil
            }
            // Report only when the content actually changed. The compare is
            // byte-exact (see `sourceChanged`) because `DocumentLoader` decides
            // whether to rebuild on UTF-8 bytes too — a canonical-equivalence
            // compare here would disagree with it and strand the cache on a
            // normalization-only rewrite. An unchanged
            // reload re-storing an identical entry would invalidate the whole
            // group view for nothing on every watcher wobble; the cache
            // already holds this content (it seeded us or stored the first
            // load). Errors (doc == nil) report too — the cache should stop
            // seeding content the disk can no longer back.
            //
            // Except an over-cap rejection, which is never cached at all. The
            // disk still backs that content perfectly well; only this viewer
            // declines to render it, and the file can drop back under the cap.
            // Caching it makes the failure *sticky* — every later remount is
            // seeded straight into the error with no reload attempt — and an
            // agent appending to an open plan file crosses the line routinely.
            //
            // Deliberately not conditioned on having a prior render: a tab
            // whose file is already over cap when it first mounts has no prior
            // render to protect, and caching the rejection there strands it
            // just the same. Re-reading costs nothing either way, because the
            // size check runs in the validator before any I/O.
            //
            // Skipping the callback also skips `noteRenderCompleted`, which is
            // already a no-op here: it guards on a non-nil source, and a
            // rejection carries none.
            if !result.isRejectedForSize,
                Self.sourceChanged(doc, priorDoc)
            {
                // `doc` is `RenderedDocument?` here (a rejected or unreadable
                // file has none).
                let sectionIndex = pane.generatedDocumentKind == .branchChanges ? doc.map(BranchDiffSectionIndex.init(document:)) : nil
                localSectionIndex = sectionIndex  // nil on failures so a stale index never outlives its document
                onRenderCompleted?(
                    DocumentTabMemory.Render(loadResult: result, renderedDoc: doc, sectionIndex: sectionIndex))
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
        snapshot: MarkdownDocumentSnapshot?
    ) -> some View {
        let snapshot = Self.editableSnapshot(snapshot, isBannerShowing: showsOversizeBanner)
        if let doc = renderedDoc {
            let isReadOnly = !pane.isEditable
            let annotationProjection = DocumentAnnotationProjection(document: doc)
            let copyModeAvailable =
                pane.isEditable && DocumentCopyModePolicy.isAvailable(in: annotationProjection)
            let copyModeActive =
                pane.isEditable
                && DocumentCopyModePolicy.isActive(
                    requested: isCopyMode,
                    projection: annotationProjection
                )
            let annotationsInteractive = snapshot != nil && !copyModeActive
            let spanTouchesMark =
                selectedSourceSpan.map {
                    SelectionSourceMapping.spanTouchesExistingMark($0, in: doc)
                } ?? false
            // Hoisted: body re-evaluates per selection event, and these build
            // fresh collections (review: avoid re-deriving them ~6x per pass).
            let hiddenIDs = DocumentCopyModePolicy.hiddenAnnotationIDs(
                in: annotationProjection,
                isCopyMode: copyModeActive,
                hideResolved: hideResolved
            )

            ZStack {
                VStack(spacing: 0) {
                    // Local first when somehow both apply: it is the one with
                    // an editing consequence to announce.
                    if showsOversizeBanner {
                        DocumentOversizeBanner(fileName: pane.title)
                    } else if let remoteStaleBannerKind {
                        DocumentOversizeBanner(fileName: pane.title, kind: remoteStaleBannerKind)
                    }
                    // Editable documents always expose the single document-note
                    // action; snapshots show it only when a note exists.
                    if !isReadOnly || annotationProjection.documentNote != nil || !doc.annotations.isEmpty {
                        documentAnnotationBar(
                            doc: doc,
                            annotationProjection: annotationProjection,
                            snapshot: snapshot
                        )
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
                            terminalBackground: NSColor(terminalBackgroundColor),
                            relativeLinkBaseURL: pane.fileURL.deletingLastPathComponent(),
                            allowsDocumentLinks: !isReadOnly,
                            annotationsInteractive: annotationsInteractive,
                            copiesPlainTextOnly: copyModeActive,
                            onPillClicked: { markID, pillRect, anchorView in
                                guard let snapshot else { return }
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
                                guard !isReadOnly, let snapshot,
                                    let span = selectedSourceSpan, !spanTouchesMark
                                else { return }
                                showComposePopover(
                                    span: span,
                                    pillRect: pillRect,
                                    anchorView: anchorView,
                                    doc: doc,
                                    snapshot: snapshot
                                )
                            },
                            selectionTouchesMark: spanTouchesMark || isReadOnly || !annotationsInteractive,
                            onTextViewAvailable: { tv in markdownNSTextView = tv },
                            // Fix 3 (INT-562): auto-present compose popover when the user
                            // finalizes a selection (mouseUp with a non-empty, non-mark-touching
                            // span). Guard: don't re-present if a popover is already open (covers
                            // the "select-to-copy" case where user cancelled then re-selects —
                            // the popover already closed on Cancel/Esc/click-away, so re-selection
                            // correctly re-opens the composer with a clean state).
                            onSelectionFinalized: { span, trailingRect, tv in
                                guard !isReadOnly, let snapshot else { return }
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
                            onSelectionChanged: { hasSelection in
                                guard
                                    transcriptReloadSelectionDeferral.resumeAfterSelectionChange(
                                        hasSelection: hasSelection
                                    )
                                else { return }
                                triggerWatcherReload()
                            },
                            protectsSelectionDuringSourceUpdates: pane.agentTranscriptIdentity != nil,
                            onSourceUpdateDeferred: {
                                if markdownNSTextView?.selectedRange().length ?? 0 > 0 {
                                    transcriptReloadSelectionDeferral.deferReload()
                                } else {
                                    triggerWatcherReload()
                                }
                            },
                            scrollAnchorOffset: pendingScrollAnchor,
                            onRegisterScrollAnchorCapture: { capture in
                                scrollAnchorCapture = capture
                                onRegisterScrollAnchorCapture?(capture)
                            },
                            onOpenDocumentLink: onOpenDocumentLink,
                            hiddenAnnotationIDs: hiddenIDs,
                            sectionIndex: localSectionIndex,
                            collapsedSections: collapsedSections,
                            onSectionToggled: onSectionToggled
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contextMenu {
                            Button("Copy") {
                                markdownNSTextView?.copy(nil)
                            }
                            .disabled(
                                markdownNSTextView?.selectedRanges.contains {
                                    $0.rangeValue.length > 0
                                } != true
                            )

                            if !isReadOnly && !copyModeActive {
                                Button("Add Comment") {
                                    guard let snapshot,
                                        let span = selectedSourceSpan, !spanTouchesMark
                                    else { return }
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
                                .disabled(snapshot == nil || selectedSourceSpan == nil || spanTouchesMark)

                                Button(
                                    annotationProjection.documentNote == nil
                                        ? "Add Document Note…" : "Document Note…"
                                ) {
                                    guard let snapshot else { return }
                                    documentNoteSheetDoc = doc
                                    documentNoteSheetSnapshot = snapshot
                                }
                                .disabled(snapshot == nil)
                            }
                            if copyModeAvailable {
                                Toggle(
                                    DocumentCopyModePresentation(isCopyMode: isCopyMode).controlTitle,
                                    isOn: $isCopyMode
                                )
                            } else {
                                Toggle("Hide Resolved Annotations", isOn: $hideResolved)
                            }
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
                        // `snapshot` is the banner-gated one above: a sheet
                        // already open when the file outgrew the cap goes
                        // read-only too, rather than committing against a
                        // snapshot the disk no longer matches.
                        allowsEditing: !isReadOnly && snapshot != nil
                    )
                }
            }
        } else {
            // Unreachable: `.loaded` always arrives with a rendered document.
            // `loadAndRender` returns a nil document only for non-`.loaded`
            // results, `DocumentTabMemory.Render.init` traps on the pairing,
            // and the two are assigned together. Kept as a spinner rather than
            // a second renderer so this branch cannot rot into a divergent
            // rendering path — it has no content to show that the real one
            // would not show better.
            ProgressView()
                .accessibilityLabel("Loading document")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Slim chrome row above the document: the single whole-document note on
    /// the leading edge and the inline resolved filter on the trailing edge.
    private func documentAnnotationBar(
        doc: RenderedDocument,
        annotationProjection: DocumentAnnotationProjection,
        snapshot: MarkdownDocumentSnapshot?
    ) -> some View {
        let documentNote = annotationProjection.documentNote
        let resolvedCount = annotationProjection.resolvedSpanCount
        let copyModeAvailable =
            pane.isEditable && DocumentCopyModePolicy.isAvailable(in: annotationProjection)
        let copyModeActive =
            pane.isEditable
            && DocumentCopyModePolicy.isActive(
                requested: isCopyMode,
                projection: annotationProjection
            )
        let copyModePresentation = DocumentCopyModePresentation(isCopyMode: isCopyMode)
        return HStack {
            if !copyModeActive && (pane.isEditable || documentNote != nil) {
                Button {
                    guard let snapshot else { return }
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
                .disabled(snapshot == nil)
                .help(documentNote == nil ? "Add a document note" : "Show document note")
                .accessibilityLabel(documentNoteAccessibilityLabel(documentNote))
            }
            Spacer()
            if copyModeAvailable {
                Toggle(isOn: $isCopyMode) {
                    Label(
                        copyModePresentation.controlTitle,
                        systemImage: isCopyMode ? "checkmark.circle.fill" : "circle"
                    )
                    .awFont(AwFont.UI.meta)
                    .fontWeight(.medium)
                    .foregroundStyle(
                        isCopyMode ? Color.aw.accentOnChrome(.mauve) : Color.aw.text2
                    )
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .help(copyModePresentation.helpText)
            } else {
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
        .onChange(of: DocumentCopyModePolicy.isAvailable(in: annotationProjection)) { _, available in
            if !available {
                isCopyMode = false
            }
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
                allowsEditing: pane.isEditable,
                onSubmissionChanged: { [weak popover] isSubmitting in
                    popover?.behavior = AnnotationPopoverLifecycle.behavior(
                        isSubmitting: isSubmitting
                    )
                },
                annotationHandoff: annotationHandoffProvider?(),
                onSendToAgent: { [weak popover] in
                    popover?.close()
                    onSendAnnotation(markID, doc.openAnnotationIDs)
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
        guard pane.isEditable else {
            if pane.generatedDocumentKind == .agentTranscript {
                showAlert(
                    title: String(
                        localized: "Read-Only Transcript",
                        comment: "Alert title when the user tries to annotate a generated agent transcript"),
                    message: String(
                        localized:
                            "Agent transcripts are rendered from the session's log and cannot be edited.",
                        comment: "Alert body explaining why a generated agent transcript rejects an edit")
                )
            } else if pane.generatedDocumentKind == .branchChanges {
                showAlert(
                    title: String(
                        localized: "Read-Only Diff",
                        comment: "Alert title when the user tries to annotate a generated branch diff"),
                    message: String(
                        localized:
                            "Branch changes are rendered from the repository and cannot be edited.",
                        comment: "Alert body explaining why a generated branch diff rejects an edit")
                )
            } else if pane.remoteResourceIdentity != nil {
                showAlert(
                    title: String(
                        localized: "Read-Only Snapshot",
                        comment: "Alert title when the user tries to annotate a remote Markdown snapshot"),
                    message: String(
                        localized: "Remote Markdown snapshots cannot be edited in awesoMux yet.",
                        comment: "Alert body explaining why a remote Markdown snapshot rejects an edit")
                )
            } else {
                showAlert(
                    title: String(
                        localized: "Read-Only Generated Document",
                        comment: "Alert title when a generated document has unknown provenance"),
                    message: String(
                        localized: "This generated document cannot be edited.",
                        comment: "Alert body when a generated document has unknown provenance")
                )
            }
            return .failed
        }

        // The banner check belongs HERE, not only at the affordances that
        // `editableSnapshot` disables. The comment popovers are NSPopover
        // rootViews handed over imperatively, and their save closures capture
        // the snapshot BY VALUE when the popover opens — so one opened before
        // the file crossed the cap still holds a usable snapshot, and gating
        // presentation does nothing for it. Without this guard that save
        // reaches `commitObserved`, whose re-read now rejects the file for
        // size, which returns `.observedConflict`, which reloads back into the
        // banner and tells the user to try again: an unwinnable loop on the
        // exact scenario this feature exists for. Every write routes through
        // this function, so one guard closes all of them.
        //
        // A terminal outcome rather than an alert: the outcome is what the
        // popovers and the note sheet already render inline, and it is the
        // only shape that both disables their Save and keeps the typed draft
        // on screen with Copy Draft beside it. An alert would say the same
        // thing modally and leave the Save button live behind it.
        guard !showsOversizeBanner else { return .oversizeCopyOnly }

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
        case .observedConflict, .inputTooLarge:
            guard !reloadCompletion.isInvalidated else { return .failed }
            if result == .observedConflict {
                pendingScrollAnchor = nil
            }
            let generation = triggerReload()
            guard await reloadCompletion.wait(for: generation) else { return .failed }
            return AnnotationSaveRecovery.outcome(
                afterReloading: result,
                conflictOutcome: conflictOutcome
            ) ?? .failed
        case .unreadable:
            showAlert(
                title: saveFailureTitle,
                message: String(
                    localized: "The document couldn't be read from disk.",
                    comment: "Save failure alert body when the file could not be re-read"))
        case .invalidEdit:
            showAlert(
                title: saveFailureTitle,
                message: String(
                    localized: "The annotation couldn't be saved. It may be too long, invalid, or duplicated.",
                    comment: "Save failure alert body when the annotation itself is rejected")
            )
        case .outputTooLarge:
            let cap = DocumentURLValidator.maxFileSizeMegabytes
            showAlert(
                title: saveFailureTitle,
                message: String(
                    localized: "The edited document would exceed the \(cap) MB size limit.",
                    comment: "Save failure alert body when the edit would push the file over the cap; the placeholder is whole megabytes"
                ))
        case .failed(let failure):
            showAlert(title: saveFailureTitle, message: failure.message)
        }
        return .failed
    }

    /// Shared so the four save-failure alerts cannot drift apart in wording,
    /// and so the title is localized once rather than at each call site.
    private var saveFailureTitle: String {
        String(localized: "Couldn't Save", comment: "Title of the alert shown when saving an annotation fails")
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(
            withTitle: String(localized: "OK", comment: "Dismiss button on the save-failure alert"))
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
        watcher = DocumentFileWatcher(
            url: pane.fileURL,
            // A transcript's file is rewritten by the live-refresh loop for as
            // long as its agent runs, so this watcher receives writes at the
            // rate that loop renders. A trailing debounce is purely trailing:
            // it would stop updating the tab hardest exactly while the agent is
            // most active. Every other document is a file a human edits, where
            // waiting for the writing to stop is the right rule and today's
            // behaviour is what to keep.
            coalescing: pane.agentTranscriptIdentity == nil ? .debounced : .leadingEdge
        ) { [self] in
            triggerWatcherReload()
        }
        watcher?.start()
    }

    /// What the detached diff half of a watcher reload should work from, or
    /// `nil` for "reload, report nothing".
    ///
    /// A rendered agent transcript is regenerable cache (`isEditable == false`)
    /// that the live-refresh loop rewrites for as long as its session runs. It
    /// holds no user edits, so reporting one would pop the revision pill and
    /// speak "N lines changed" on every refresh. The suppression is a *value*
    /// the caller computes before it reloads rather than an early return, so it
    /// structurally cannot skip the reload that live refresh depends on.
    ///
    /// Static and pure so the rule is checkable without hosting the view.
    static func watcherRevisionContext(
        isAgentTranscript: Bool,
        selfWrite: MarkdownSelfWriteContext?,
        renderedSource: String?
    ) -> (old: String?, isSelfWrite: Bool)? {
        guard !isAgentTranscript else { return nil }
        return (selfWrite?.source ?? renderedSource, selfWrite?.isSelfWrite ?? false)
    }

    /// Whether this reload is the one that tells a VoiceOver user the
    /// transcript is being rewritten under them, latching `alreadyAnnounced`
    /// when it is.
    ///
    /// `watcherRevisionContext` leaves a screen-reader user with no signal at
    /// all that the document they are reading is changing and their position
    /// may move. The answer is one announcement, not a restored per-refresh
    /// one: the fact worth speaking is that this document is live, and it is
    /// true from the first refresh onwards, so repeating it every render would
    /// be the noise the suppression removed. `renderedSource == nil` is the
    /// initial load rather than a refresh, and the tab already announces when
    /// it opens.
    ///
    /// The latch is `inout` rather than a plain condition so the test that
    /// pins "once" exercises the same statement that sets it — a separate
    /// assignment at the call site is where this rule would drift.
    static func consumeLiveTranscriptRefreshAnnouncement(
        isAgentTranscript: Bool,
        alreadyAnnounced: inout Bool,
        renderedSource: String?,
        onDiskSource: String
    ) -> Bool {
        guard isAgentTranscript, !alreadyAnnounced else { return false }
        guard let renderedSource, renderedSource != onDiskSource else { return false }
        alreadyAnnounced = true
        return true
    }

    /// Static and non-private for the same reason as `readErrorMessage`: a test
    /// can assert what the user actually hears.
    static let liveTranscriptRefreshAnnouncement = String(
        localized: "Transcript is updating live.",
        comment:
            "VoiceOver announcement the first time an open agent transcript is rewritten by its running session"
    )

    private func triggerWatcherReload() {
        guard
            transcriptReloadSelectionDeferral.shouldStartWatcherReload(
                hasSelection: markdownNSTextView?.selectedRange().length ?? 0 > 0
            )
        else { return }

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
                // `readSnapshot` returns nil for an over-cap file, and going
                // over cap is routine — an agent appending to an open plan
                // file does it. Keep the captured anchor rather than clearing
                // it: the load task retains the mounted render behind the
                // oversize banner, so there is still a live position to hold,
                // and it is where the reader was if the file drops back under.
                // The load task, not this branch, decides which reload result
                // is retained; the anchor is only wasted state when it isn't.
                guard let onDisk, let onDiskSource = onDisk.source else {
                    pendingScrollAnchor = anchor
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
                let context = Self.watcherRevisionContext(
                    isAgentTranscript: pane.agentTranscriptIdentity != nil,
                    selfWrite: selfWrite,
                    renderedSource: renderedDoc?.source
                )
                // Reads `renderedDoc` for the same reason the line above does,
                // and must stay above `triggerReload`: this is the last point
                // where the pre-reload source is still what the user has seen.
                if Self.consumeLiveTranscriptRefreshAnnouncement(
                    isAgentTranscript: pane.agentTranscriptIdentity != nil,
                    alreadyAnnounced: &announcedLiveTranscriptRefresh,
                    renderedSource: renderedDoc?.source,
                    onDiskSource: onDiskSource
                ) {
                    TerminalAccessibilityAnnouncer.announce(
                        Self.liveTranscriptRefreshAnnouncement
                    )
                }
                pendingScrollAnchor = anchor
                triggerReload(snapshot: onDisk)
                if context == nil { watcherReloadTask = nil }
                return context
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

    /// Frames a `DocumentLoader` read failure with the file it happened to.
    ///
    /// The interpolated reason is localized where it is produced, in
    /// `DocumentLoader` — framing an English payload in a localized sentence
    /// would be worse than leaving both alone, so the two must stay in step.
    static func readErrorMessage(_ reason: String, pane: DocumentPane) -> String {
        String(
            localized: "Couldn't read \u{201C}\(pane.title)\u{201D}: \(reason)",
            comment:
                "Document pane error; first placeholder is the quoted file name, second is the localized reason"
        )
    }

    /// Static and non-private so a test can assert what the user actually
    /// reads. Note what such a test can and cannot see: `Localizable.xcstrings`
    /// is not a declared SwiftPM resource, so under `swift test` these always
    /// render the source literal. A rendered-string assertion therefore checks
    /// the source only — `DocumentRejectionCopyCatalogTests` reads the catalog
    /// file directly for the other half.
    static func rejectionMessage(
        for reason: DocumentURLValidator.Rejection,
        pane: DocumentPane
    ) -> String {
        // Localized here rather than at the `Text` that renders it: the view
        // uses `Text(String)`, which is the non-localizing initializer, so a
        // raw string built here would reach the user in English regardless of
        // locale. Resolving at construction keeps the call site unchanged.
        let q = "\u{201C}\(pane.title)\u{201D}"
        switch reason {
        case .notFileURL:
            return String(
                localized: "Can't open \(q): the path is not a local file URL.",
                comment: "Document pane error; the placeholder is the quoted file name")
        case .badExtension:
            let allowed = DocumentURLValidator.allowedExtensions.sorted().joined(separator: ", ")
            return String(
                localized: "Can't open \(q): only these file types are supported: \(allowed).",
                comment:
                    "Document pane error; first placeholder is the quoted file name, second is a comma-separated extension list"
            )
        case .tooLarge:
            let cap = DocumentURLValidator.maxFileSizeMegabytes
            return String(
                localized: "Can't open \(q): file exceeds the \(cap) MB size limit.",
                comment: "Document pane error; first placeholder is the quoted file name, second is the cap in whole megabytes")
        case .unreadable:
            return String(
                localized: "Can't open \(q): the file couldn't be read (missing or no permission).",
                comment: "Document pane error; the placeholder is the quoted file name")
        }
    }
}
