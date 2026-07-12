import Foundation

struct WorkspaceAttentionReducer: Sendable {
    struct SessionUpdate: Sendable {
        var title: String?
        var workingDirectory: String?
        var agentKind: AgentKind?
        var agentState: AgentState?
        var agentExecutionState: AgentExecutionState?
        var attentionReason: AttentionReason?
        var clearsAttention: Bool
        var clearsUnreadNotifications: Bool
        var unreadNotificationDelta: Int

        init(
            title: String? = nil,
            workingDirectory: String? = nil,
            agentKind: AgentKind? = nil,
            agentState: AgentState? = nil,
            agentExecutionState: AgentExecutionState? = nil,
            attentionReason: AttentionReason? = nil,
            clearsAttention: Bool = false,
            clearsUnreadNotifications: Bool = false,
            unreadNotificationDelta: Int = 0
        ) {
            self.title = title
            self.workingDirectory = workingDirectory
            self.agentKind = agentKind
            self.agentState = agentState
            self.agentExecutionState = agentExecutionState
            self.attentionReason = attentionReason
            self.clearsAttention = clearsAttention
            self.clearsUnreadNotifications = clearsUnreadNotifications
            self.unreadNotificationDelta = unreadNotificationDelta
        }
    }

    struct UnreadChange: Equatable, Sendable {
        var oldCount: Int
        var newCount: Int
    }

    /// Applies a `SessionUpdate` to one pane (the agent fields) and the session
    /// (title / working directory). Post INT-504 agent state lives on the pane;
    /// the session derives its rollup. `paneID` is the pane the runtime event was
    /// keyed to, so split sessions no longer collapse to last-write-wins.
    static func updatePane(
        _ session: inout TerminalSession,
        paneID: TerminalPane.ID,
        update: SessionUpdate,
        now: Date
    ) -> UnreadChange? {
        let oldUnreadCount = session.unreadNotificationCount

        if let title = update.title {
            let title = SessionStoreText.sanitizedTitle(title)
            if !title.isEmpty {
                session.title = title
                session.isTitleUserEdited = true
            }
        }

        if let workingDirectory = update.workingDirectory.flatMap({
            WorkingDirectoryValidator.validatedReportedDirectory($0)
        }) {
            session.workingDirectory = workingDirectory
        }

        session.layout = session.layout.mappingPanes { pane in
            guard pane.id == paneID else { return pane }
            var pane = pane

            if let agentKind = update.agentKind {
                pane.agentKind = agentKind
            }

            if let agentExecutionState = update.agentExecutionState {
                // `lastAgentStateChangeAt` is refreshed on EVERY execution-state
                // event, including a repeat of the same state: it doubles as an
                // activity heartbeat that `isQuitRisk()` reads, so a repeated
                // "still thinking" is a liveness signal that keeps the agent out
                // of quit-risk. (A review pass flagged the per-second re-render
                // this causes; the fix can't be an inline value-equality gate
                // because the timestamp must refresh for liveness yet lives in
                // the rendered layout — decoupling the two is a tracked
                // follow-up, not a safe one-liner.)
                pane.agentExecutionState = agentExecutionState
                pane.lastAgentStateChangeAt = now
            }

            if let agentState = update.agentState {
                pane.applyLegacyAgentState(
                    agentState,
                    clearsAttentionForExecutionState: update.clearsAttention
                )
                pane.lastAgentStateChangeAt = now
            }

            if let attentionReason = update.attentionReason {
                // A lower-priority reason (e.g. `.bell`) must not clobber a
                // higher-priority PENDING one (e.g. `.permissionPrompt`) still
                // awaiting the user (INT-506). Clearing is handled separately
                // below and always wins.
                if let current = pane.attentionReason,
                   current.priority > attentionReason.priority {
                    // keep current
                } else {
                    pane.attentionReason = attentionReason
                }
            } else if update.clearsAttention {
                pane.attentionReason = nil
            }

            if update.clearsUnreadNotifications {
                pane.unreadNotificationCount = 0
            } else if update.unreadNotificationDelta != 0 {
                pane.unreadNotificationCount = max(
                    0,
                    pane.unreadNotificationCount + update.unreadNotificationDelta
                )
            }

            return pane
        }

        return unreadChange(from: oldUnreadCount, to: session.unreadNotificationCount)
    }

    /// Acknowledges a single pane — drops its unread badge and attention. The
    /// selection-dwell ack and the per-row ⌘K clear the *active* pane only, so a
    /// sibling pane still needing input keeps the workspace row loud (ADR-0003
    /// amendment).
    static func acknowledgePane(
        _ session: inout TerminalSession,
        paneID: TerminalPane.ID
    ) -> UnreadChange? {
        let oldUnreadCount = session.unreadNotificationCount
        session.layout = session.layout.mappingPanes { pane in
            guard pane.id == paneID else { return pane }
            var pane = pane
            pane.unreadNotificationCount = 0
            pane.attentionReason = nil
            return pane
        }
        return unreadChange(from: oldUnreadCount, to: session.unreadNotificationCount)
    }

    /// Mirrors the live bridge permission queue into persistent pane chrome
    /// without clearing unrelated notification counts. Permission prompts add
    /// one unread unit each; draining removes only those units, and clears the
    /// reason only when it is still the bridge-owned reason.
    static func updatePermissionPromptAttention(
        _ session: inout TerminalSession,
        paneID: TerminalPane.ID,
        countDelta: Int,
        hasPending: Bool
    ) -> UnreadChange? {
        let oldUnreadCount = session.unreadNotificationCount
        session.layout = session.layout.mappingPanes { pane in
            guard pane.id == paneID else { return pane }
            var pane = pane
            pane.unreadNotificationCount = max(0, pane.unreadNotificationCount + countDelta)
            if hasPending {
                pane.attentionReason = .permissionPrompt
            } else if pane.attentionReason == .permissionPrompt {
                pane.attentionReason = nil
            }
            return pane
        }
        return unreadChange(from: oldUnreadCount, to: session.unreadNotificationCount)
    }

    /// Acknowledges every pane in ONE workspace — the ⌘⇧K "Acknowledge Workspace"
    /// escape hatch. Drops each pane's unread badge and attention so the whole
    /// workspace row goes quiet, unlike `acknowledgePane` (active pane only).
    /// The all-WORKSPACES sweep is `acknowledgeAllSessions` ("Clear All
    /// Notifications"). INT-504 R3.
    static func acknowledgeAllPanes(in session: inout TerminalSession) -> UnreadChange? {
        let oldUnreadCount = session.unreadNotificationCount
        session.layout = session.layout.mappingPanes { pane in
            guard pane.attentionReason != nil || pane.unreadNotificationCount != 0 else {
                return pane
            }
            var pane = pane
            pane.unreadNotificationCount = 0
            pane.attentionReason = nil
            return pane
        }
        return unreadChange(from: oldUnreadCount, to: session.unreadNotificationCount)
    }

    /// The all-workspaces escape hatch ("Clear All Notifications"): clears every
    /// pane in every session. ⌘⇧K ("Acknowledge Workspace") clears one workspace
    /// via `acknowledgeAllPanes(in:)`.
    static func acknowledgeAllSessions(in groups: inout [SessionGroup]) {
        for groupIndex in groups.indices {
            for sessionIndex in groups[groupIndex].sessions.indices {
                groups[groupIndex].sessions[sessionIndex].layout =
                    groups[groupIndex].sessions[sessionIndex].layout.mappingPanes { pane in
                        var pane = pane
                        pane.unreadNotificationCount = 0
                        pane.attentionReason = nil
                        return pane
                    }
            }
        }
    }

    /// Clears a leftover `.error` execution state on the given pane (or, when
    /// `paneID` is nil, every pane). Returns whether anything changed.
    static func clearStaleErrorIfPresent(
        _ session: inout TerminalSession,
        paneID: TerminalPane.ID?,
        now: Date
    ) -> Bool {
        var didChange = false
        session.layout = session.layout.mappingPanes { pane in
            guard paneID == nil || pane.id == paneID else { return pane }
            guard pane.agentExecutionState == .error else { return pane }
            var pane = pane
            pane.agentExecutionState = .idle
            pane.lastAgentStateChangeAt = now
            didChange = true
            return pane
        }
        return didChange
    }

    /// Records that a pane's process exited with an error. The attention lands on
    /// `paneID` — the held-dead pane (INT-506) when one exists, else the active
    /// pane. A non-focused terminal also gets an unread badge so the workspace
    /// row surfaces the failure. INT-504 R7.
    static func recordPaneExitError(
        _ session: inout TerminalSession,
        paneID: TerminalPane.ID,
        terminalIsFocused: Bool
    ) -> UnreadChange? {
        let oldUnreadCount = session.unreadNotificationCount
        session.layout = session.layout.mappingPanes { pane in
            guard pane.id == paneID else { return pane }
            var pane = pane
            let enteringNeedsAttention = pane.agentExecutionState != .error
                && pane.attentionReason == nil
            if enteringNeedsAttention && !terminalIsFocused {
                pane.unreadNotificationCount += 1
            }
            // Guard on `attentionReason == nil` so a live prompt (e.g. a
            // permission request the user still needs to answer) isn't silently
            // overwritten by `.processError` (consistency, INT-504 review).
            if enteringNeedsAttention {
                pane.attentionReason = .processError
            }
            return pane
        }
        return unreadChange(from: oldUnreadCount, to: session.unreadNotificationCount)
    }

    private static func unreadChange(from old: Int, to new: Int) -> UnreadChange? {
        guard old != new else { return nil }
        return UnreadChange(oldCount: old, newCount: new)
    }
}
