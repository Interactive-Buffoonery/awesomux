import AwesoMuxBridgeProtocol
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

    /// Result of `updatePane`: the unread delta (if any) plus whether ANY field
    /// actually changed value. `didMutate` is what lets the store skip writing
    /// the reducer's output back into `_groups` (and skip the @Observable
    /// publish that write triggers) for a same-state repeat — see
    /// `SessionStore.applyPaneUpdate`.
    struct PaneUpdateOutcome: Equatable, Sendable {
        var unreadChange: UnreadChange?
        /// True when any field of the session or its panes was written —
        /// including a due heartbeat refresh. False means the caller must not
        /// touch `_groups` (no @Observable publish) and may skip risk
        /// reclassification.
        var didMutate: Bool
    }

    /// Refreshes `pane.lastAgentStateChangeAt` — the liveness heartbeat
    /// `isQuitRisk()` reads — and reports whether it mutated. `changed` covers
    /// the case where the caller just wrote a genuinely new state (always
    /// refresh); otherwise this is a same-state repeat ("still thinking"),
    /// which only refreshes once the stamp has gone stale past
    /// `agentActivityFreshnessCoarsening` — the same 10s grain
    /// `markAgentActivityObserved` uses, which the 60s staleness threshold
    /// already tolerates. Sub-window repeats mutate nothing, so they no
    /// longer publish the store. Shared by the execution-state and legacy
    /// agent-state branches below so this rule can't drift between them.
    private static func refreshHeartbeatIfDue(
        _ pane: inout TerminalPane,
        now: Date,
        changed: Bool
    ) -> Bool {
        guard
            changed
                || now.timeIntervalSince(pane.lastAgentStateChangeAt)
                    >= SessionStore.agentActivityFreshnessCoarsening
        else {
            return false
        }
        pane.lastAgentStateChangeAt = now
        return true
    }

    /// Applies a `SessionUpdate` to one pane (the agent fields) and the session
    /// (title / working directory). Post INT-504 agent state lives on the pane;
    /// the session derives its rollup. `paneID` is the pane the runtime event was
    /// keyed to, so split sessions no longer collapse to last-write-wins.
    ///
    /// Every assignment below is gated on the written value actually differing
    /// from the current one — NOT on `TerminalPane`'s `Equatable` conformance,
    /// which deliberately excludes runtime-only fields (`lastAgentStateChangeAt`
    /// included). Comparing whole panes would silently swallow a due heartbeat
    /// refresh (a `lastAgentStateChangeAt`-only change) and strand the freshness
    /// stamp forever.
    static func updatePane(
        _ session: inout TerminalSession,
        paneID: TerminalPane.ID,
        update: SessionUpdate,
        now: Date
    ) -> PaneUpdateOutcome {
        let oldUnreadCount = session.unreadNotificationCount
        var didMutate = false

        if let title = update.title {
            let title = SessionStoreText.sanitizedTitle(title)
            if !title.isEmpty, session.title != title || !session.isTitleUserEdited {
                session.title = title
                session.isTitleUserEdited = true
                didMutate = true
            }
        }

        if let workingDirectory = update.workingDirectory.flatMap({
            WorkingDirectoryValidator.validatedReportedDirectory($0)
        }), session.workingDirectory != workingDirectory {
            session.workingDirectory = workingDirectory
            didMutate = true
        }

        // ponytail: `mappingPanes` reboxes the whole indirect-enum layout tree
        // on every call, even for the untouched panes and even on a quiet
        // same-state repeat that ends up mutating nothing — O(panes)
        // allocations per event, discarded the moment `didMutate` stays
        // false. Fine at today's pane counts; if a many-split session makes
        // this show up in a trace, the upgrade path is a read-only pre-peek
        // of the target pane (skip the rebox entirely when nothing about it
        // would change) before falling back to this mapping pass.
        session.layout = session.layout.mappingPanes { pane in
            guard pane.id == paneID else { return pane }
            var pane = pane

            if let agentKind = update.agentKind, agentKind != pane.agentKind {
                pane.agentKind = agentKind
                didMutate = true
            }

            if let agentExecutionState = update.agentExecutionState {
                let changed = agentExecutionState != pane.agentExecutionState
                if changed {
                    pane.agentExecutionState = agentExecutionState
                }
                if refreshHeartbeatIfDue(&pane, now: now, changed: changed) {
                    didMutate = true
                }
            }

            if let agentState = update.agentState {
                // `applyLegacyAgentState` touches EXACTLY these two fields — snapshot
                // and compare them rather than the whole pane (see the doc comment
                // above on why whole-pane equality is unsafe here).
                let beforeExecutionState = pane.agentExecutionState
                let beforeAttentionReason = pane.attentionReason
                pane.applyLegacyAgentState(
                    agentState,
                    clearsAttentionForExecutionState: update.clearsAttention
                )
                let stateChanged =
                    pane.agentExecutionState != beforeExecutionState
                    || pane.attentionReason != beforeAttentionReason
                if refreshHeartbeatIfDue(&pane, now: now, changed: stateChanged) {
                    didMutate = true
                }
            }

            if let attentionReason = update.attentionReason {
                // A lower-priority reason (e.g. `.bell`) must not clobber a
                // higher-priority PENDING one (e.g. `.permissionPrompt`) still
                // awaiting the user (INT-506). Clearing is handled separately
                // below and always wins.
                if let current = pane.attentionReason,
                    current.priority > attentionReason.priority
                {
                    // keep current
                } else if pane.attentionReason != attentionReason {
                    pane.attentionReason = attentionReason
                    didMutate = true
                }
            } else if update.clearsAttention, pane.attentionReason != nil {
                pane.attentionReason = nil
                didMutate = true
            }

            if update.clearsUnreadNotifications {
                if pane.unreadNotificationCount != 0 {
                    pane.unreadNotificationCount = 0
                    didMutate = true
                }
            } else if update.unreadNotificationDelta != 0 {
                let newCount = max(0, pane.unreadNotificationCount + update.unreadNotificationDelta)
                if newCount != pane.unreadNotificationCount {
                    pane.unreadNotificationCount = newCount
                    didMutate = true
                }
            }

            return pane
        }

        return PaneUpdateOutcome(
            unreadChange: unreadChange(from: oldUnreadCount, to: session.unreadNotificationCount),
            didMutate: didMutate
        )
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
            let enteringNeedsAttention =
                pane.agentExecutionState != .error
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
