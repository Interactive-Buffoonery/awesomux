import AwesoMuxBridgeProtocol
import Foundation

/// Tracks per-workspace rollup-state transitions and emits accessibility
/// announcements when a workspace crosses INTO an attention-worthy state
/// (`.needsAttention` / `.done` / `.error`) while it is NOT focused — the
/// WCAG 4.1.3 "status message" signal a sighted user gets from the sidebar
/// badge but a VoiceOver user otherwise misses (INT-504 review, major a11y finding).
///
/// Pure and deterministic so the transition logic can be unit-tested; the app
/// layer owns the actual `NSAccessibility.post` and the debounce that keeps N
/// panes finishing at once from machine-gunning VoiceOver.
public struct WorkspaceAttentionAnnouncementTracker: Sendable {
    public struct Announcement: Equatable, Sendable {
        public let sessionID: TerminalSession.ID
        public let title: String
        public let agentKind: AgentKind
        public let state: AgentDisplayState

        public init(
            sessionID: TerminalSession.ID,
            title: String,
            agentKind: AgentKind,
            state: AgentDisplayState
        ) {
            self.sessionID = sessionID
            self.title = title
            self.agentKind = agentKind
            self.state = state
        }
    }

    private var lastStateBySessionID: [TerminalSession.ID: AgentDisplayState]

    public init(groups: [SessionGroup] = []) {
        lastStateBySessionID = Self.statesBySessionID(in: groups)
    }

    /// Re-seeds the baseline without emitting announcements — used at bind so a
    /// restored workspace that was already loud doesn't get spoken on launch.
    public mutating func reset(groups: [SessionGroup]) {
        lastStateBySessionID = Self.statesBySessionID(in: groups)
    }

    /// A transition INTO one of these gets announced. `.done`/`.error` are
    /// included alongside `.needsAttention`: they are terminal outcomes a
    /// VoiceOver user wants to hear about for an unfocused workspace.
    public static func isAnnounceWorthy(_ state: AgentDisplayState) -> Bool {
        switch state {
        case .needsAttention, .done, .error:
            true
        case .idle, .running, .waiting, .thinking, .output:
            false
        }
    }

    /// A `.processError` crossing already gets a specific "pane exited with
    /// error" VoiceOver announcement from the view layer at the moment
    /// `recordSiblingPaneExitError` fires (`TerminalAccessibilityAnnouncer
    /// .announceSiblingPaneExitError`, GhosttySurfaceProcessExitHandler). That
    /// collapses to the same generic `.needsAttention` rollup state this
    /// tracker also speaks for, so without this check both fire for one event
    /// (INT-642). The specific message wins — skip the generic one here.
    ///
    /// Per-pane, not winner-only: suppress ONLY when every attention-needing
    /// pane is `.processError`. Every reason collapses to the same
    /// `.needsAttention` priority tier, so the winner on ties is traversal
    /// order — a `.processError` winner can sit next to a `.permissionPrompt`
    /// sibling nobody else announces, and that sibling must still be spoken
    /// (INT-504 session-vs-pane scoping).
    public static func isDuplicateOfSpecificAnnouncement(_ rollup: SessionAgentRollup) -> Bool {
        guard rollup.state == .needsAttention else { return false }
        let reasons = rollup.attentionReasons
        return !reasons.isEmpty && reasons.allSatisfy { $0 == .processError }
    }

    public mutating func announcements(
        afterUpdating groups: [SessionGroup],
        selectedSessionID: TerminalSession.ID?,
        isAppActive: Bool
    ) -> [Announcement] {
        var result: [Announcement] = []
        var seen = Set<TerminalSession.ID>()

        for group in groups {
            for session in group.sessions {
                seen.insert(session.id)
                let rollup = session.agentRollup()
                let newState = rollup.state
                let previousState = lastStateBySessionID[session.id]
                lastStateBySessionID[session.id] = newState

                guard Self.isAnnounceWorthy(newState),
                      newState != previousState,
                      !Self.isDuplicateOfSpecificAnnouncement(rollup) else {
                    continue
                }

                // Only announce when the workspace is unfocused — a focused
                // workspace's state is already on screen for the user. The
                // baseline still advances above, so re-focusing later does not
                // replay the announcement.
                let isFocused = isAppActive && session.id == selectedSessionID
                guard !isFocused else {
                    continue
                }

                result.append(Announcement(
                    sessionID: session.id,
                    title: session.title,
                    agentKind: rollup.winningAgentKind,
                    state: newState
                ))
            }
        }

        for sessionID in Array(lastStateBySessionID.keys) where !seen.contains(sessionID) {
            lastStateBySessionID.removeValue(forKey: sessionID)
        }

        return result
    }

    /// Collapses a debounced batch before it is spoken and REBUILDS each survivor
    /// from the live rollup. Dedupes per workspace (a workspace that transitioned
    /// twice in one window must not be counted twice — R2) and, for each distinct
    /// workspace, asks `liveAnnouncement` for the workspace's CURRENT announcement.
    ///
    /// Returning the live announcement (vs the enqueued one) closes two gaps:
    /// the workspace whose rollup reverted out of an announce-worthy state during
    /// the window returns nil and is dropped (no stale "needs input"); and a
    /// workspace whose title / winning pane / winning kind changed while staying
    /// announce-worthy is spoken with its LIVE identity, not the stale snapshot
    /// captured at crossing time (INT-504 R2). First-seen order is preserved so
    /// the spoken single-workspace case names a stable winner.
    public static func reconcile(
        _ batch: [Announcement],
        liveAnnouncement: (TerminalSession.ID) -> Announcement?
    ) -> [Announcement] {
        var seen = Set<TerminalSession.ID>()
        var order: [TerminalSession.ID] = []
        for announcement in batch where seen.insert(announcement.sessionID).inserted {
            order.append(announcement.sessionID)
        }
        return order.compactMap { liveAnnouncement($0) }
    }

    /// The spoken string for a debounced batch of crossings. A single crossing
    /// names the workspace and its loudest agent; a same-window burst across
    /// DISTINCT workspaces collapses to a count so VoiceOver isn't machine-gunned.
    /// Returns nil for an empty batch. Pass a `reconcile`d batch so the count
    /// reflects distinct workspaces. Phrasing mirrors the sidebar/dock wording
    /// (INT-505 / INT-469).
    public static func spokenAnnouncement(
        for batch: [Announcement],
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String? {
        guard let first = batch.first else {
            return nil
        }
        if batch.count == 1 {
            return message(for: first, bundle: bundle, locale: locale)
        }
        let format = String(
            localized: "accessibility.workspaceAttention.workspacesNeedAttention",
            bundle: bundle,
            locale: locale,
            comment: "VoiceOver announcement for a batch of workspaces that need attention. Argument is the workspace count."
        )
        let resolved = format == "accessibility.workspaceAttention.workspacesNeedAttention"
            ? "%lld workspaces need attention."
            : format
        return String(format: resolved, locale: locale, arguments: [batch.count])
    }

    static func message(
        for announcement: Announcement,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        let trimmed = announcement.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = trimmed.isEmpty
            ? String(localized: "a workspace", bundle: bundle, locale: locale, comment: "Fallback name in a VoiceOver workspace announcement")
            : trimmed
        let agent = announcement.agentKind.localizedSpokenName(bundle: bundle, locale: locale)
        switch announcement.state {
        case .needsAttention:
            let format = String(
                localized: "%1$@ in %2$@ needs input.",
                bundle: bundle,
                locale: locale,
                comment: "VoiceOver announcement that an agent in a background workspace needs input."
            )
            return String(format: format, locale: locale, arguments: [agent, workspace])
        case .done:
            let format = String(
                localized: "%1$@ in %2$@ completed.",
                bundle: bundle,
                locale: locale,
                comment: "VoiceOver announcement that an agent in a background workspace completed."
            )
            return String(format: format, locale: locale, arguments: [agent, workspace])
        case .error:
            let format = String(
                localized: "%1$@ in %2$@ reported an error.",
                bundle: bundle,
                locale: locale,
                comment: "VoiceOver announcement that an agent in a background workspace reported an error."
            )
            return String(format: format, locale: locale, arguments: [agent, workspace])
        case .idle, .running, .waiting, .thinking, .output:
            let format = String(
                localized: "%@ needs attention.",
                bundle: bundle,
                locale: locale,
                comment: "Fallback VoiceOver announcement that a background workspace needs attention."
            )
            return String(format: format, locale: locale, arguments: [workspace])
        }
    }

    private static func statesBySessionID(
        in groups: [SessionGroup]
    ) -> [TerminalSession.ID: AgentDisplayState] {
        var states: [TerminalSession.ID: AgentDisplayState] = [:]
        for group in groups {
            for session in group.sessions {
                states[session.id] = session.agentRollup().state
            }
        }
        return states
    }
}
