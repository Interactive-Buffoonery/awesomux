import AwesoMuxBridgeProtocol
import Foundation

struct AgentRuntimeEventReducer: Sendable {
    struct RuntimeEventState: Sendable {
        enum Lifecycle: Sendable {
            case active
            case stopped
            case superseded
            case supersededStopped
            case ended

            var isEnded: Bool {
                self == .ended
            }

            var currentIsStopped: Bool {
                self == .stopped || self == .supersededStopped
            }

            var hasSupersededLifecycle: Bool {
                self == .superseded || self == .supersededStopped
            }

            mutating func start() {
                switch self {
                case .stopped, .superseded, .supersededStopped, .ended:
                    self = .superseded
                case .active:
                    self = .active
                }
            }

            mutating func stop() {
                switch self {
                case .active, .stopped:
                    self = .stopped
                case .superseded, .supersededStopped:
                    self = .supersededStopped
                case .ended:
                    break
                }
            }
        }

        static let recentEventIDCapacity = 64
        var recentEventIDs: [String] = []
        var lastAppliedTimestamp: Date?
        // Arrival-order lifecycle state complements timestamps: it suppresses
        // both post-exit Stop events and an old SessionEnd delivered after a
        // stopped lifecycle has been superseded in the same pane.
        var lifecycle = Lifecycle.active
        var suppressesHeuristicState = false
        // Grok emits hooks for child agents too. Latch the parent session id so
        // child lifecycle events do not flip the parent tile.
        var providerSessionID: String?
    }

    /// A pane-title mutation a `.rename` event resolves to, applied by the store
    /// alongside the `update`. Routing rename through the reducer (rather than
    /// the surface bypassing it) means it inherits the same `(eventID, timestamp)`
    /// dedupe + staleness guards as state events, so a replayed or out-of-order
    /// rename can't overwrite a newer title (cross-model review).
    enum PaneTitleAction: Sendable, Equatable {
        case rename(String)
        case reset
    }

    enum DocumentPaneAction: Sendable, Equatable {
        case open(URL)
    }

    struct Decision: Sendable {
        var update: WorkspaceAttentionReducer.SessionUpdate
        var appliesPaneUpdate: Bool
        var paneTitleAction: PaneTitleAction?
        var documentPaneAction: DocumentPaneAction?

        init(
            update: WorkspaceAttentionReducer.SessionUpdate,
            appliesPaneUpdate: Bool = true,
            paneTitleAction: PaneTitleAction? = nil,
            documentPaneAction: DocumentPaneAction? = nil
        ) {
            self.update = update
            self.appliesPaneUpdate = appliesPaneUpdate
            self.paneTitleAction = paneTitleAction
            self.documentPaneAction = documentPaneAction
        }
    }

    var stateByPaneID: [TerminalPane.ID: RuntimeEventState] = [:]

    func suppressesHeuristicState(for paneID: TerminalPane.ID) -> Bool {
        stateByPaneID[paneID]?.suppressesHeuristicState == true
    }

    mutating func decision(
        for event: AgentRuntimeEvent,
        currentSession: TerminalSession?,
        paneID: TerminalPane.ID,
        terminalIsFocused: Bool,
        now: Date
    ) -> Decision? {
        guard let currentSession,
            let currentPane = currentSession.layout.pane(id: paneID)
        else {
            stateByPaneID[paneID] = nil
            return nil
        }

        var state = stateByPaneID[paneID, default: RuntimeEventState()]
        // Invariant: the dedup (here) and staleness (below) guards return without
        // writing `state` back. That is only safe because nothing mutates the
        // local `state` before either guard — keep it that way, or persist on the
        // early-return paths so a future mutation isn't silently dropped.
        let dedupeKey = event.eventID.map { id in
            "\(id)|\(event.timestamp?.timeIntervalSince1970 ?? 0)"
        }
        if let key = dedupeKey, state.recentEventIDs.contains(key) {
            return nil
        }

        // A subprocess CLI invocation (e.g. `codex exec` run as a Bash tool call
        // inside a Claude Code pane) inherits the pane's AWESOMUX_AGENT_EVENT_FILE
        // and, if it has its own awesoMux status hooks installed, writes its own
        // lifecycle events into this pane's stream (confirmed live — see Task 2
        // background). A bare SessionStart is not enough to prove a genuine
        // foreground handoff: a nested child process fires its own SessionStart
        // too, while the pane's real established agent is still `.active`
        // mid-turn. Only trust a different-kind SessionStart once the established
        // agent's own tracked lifecycle shows it has stopped or fully ended — i.e.
        // it's between turns or gone, not mid-turn. Everything else from a
        // different provider is rejected outright, before it can touch dedupe,
        // staleness, or lifecycle state for the pane's real agent.
        if let eventKind = event.kind,
            currentPane.agentKind != .shell,
            currentPane.agentKind != eventKind,
            !(event.phase == .sessionStart && (state.lifecycle.isEnded || state.lifecycle.currentIsStopped))
        {
            return nil
        }

        if shouldDropGrokChildSessionEvent(event, state: state) {
            return nil
        }

        // Session exit is terminal: the agent is gone, so a full reset must apply
        // even if shutdown's timestamp lands at or before a recent turn-end Stop.
        // Bypass the staleness guard (the reset is idempotent) and latch the pane
        // so a later buffered Stop can't reapply waiting, re-peach it, or
        // resurrect the agent glyph.
        if event.phase == .sessionEnd {
            if state.lifecycle.hasSupersededLifecycle,
                !state.lifecycle.currentIsStopped,
                (normalizedProviderSessionID(state.providerSessionID) == nil
                    || normalizedProviderSessionID(event.providerSessionID) == nil)
            {
                return nil
            }
            state.lifecycle = .ended
            state.suppressesHeuristicState =
                state.suppressesHeuristicState
                || event.source.hasTrustworthySessionRestartBoundary
            if event.source == .grok {
                state.providerSessionID = nil
            }
            advanceTimestampWatermark(event.timestamp, now: now, into: &state)
            stateByPaneID[paneID] = state
            return Decision(
                update: WorkspaceAttentionReducer.SessionUpdate(
                    agentKind: .shell,
                    agentExecutionState: event.executionState ?? .idle,
                    clearsAttention: true,
                    clearsUnreadNotifications: true
                ))
        }

        let restartsStoppedLifecycle =
            event.phase == .sessionStart && state.lifecycle.currentIsStopped
        let restartsEndedLifecycle =
            event.phase == .sessionStart && state.lifecycle.isEnded
        if let timestamp = event.timestamp,
            let lastTimestamp = state.lastAppliedTimestamp
        {
            // An ended lifecycle accepts a restart at the watermark (end and
            // restart can land in the same flush with equal timestamps), but a
            // strictly older replayed SessionStart must not revive the pane.
            if restartsEndedLifecycle {
                if timestamp < lastTimestamp {
                    return nil
                }
            } else if !restartsStoppedLifecycle, timestamp <= lastTimestamp {
                return nil
            }
        }

        // A rename event is title-only: it carries a pane title, never agent
        // state. It has now cleared the same dedupe + staleness guards as a state
        // event. Record it (so a replay is deduped) and emit a pane-title action;
        // an absent title is malformed and dropped, an empty title resets.
        if event.phase == .rename {
            guard event.executionState == nil,
                event.attentionReason == nil,
                event.state == nil,
                let rawTitle = event.title
            else {
                return nil
            }
            recordApplied(
                dedupeKey: dedupeKey, timestamp: event.timestamp, now: now, into: &state
            )
            stateByPaneID[paneID] = state
            let action: PaneTitleAction =
                SessionStoreText.sanitizedTitle(rawTitle).isEmpty
                ? .reset
                : .rename(rawTitle)
            return Decision(
                update: WorkspaceAttentionReducer.SessionUpdate(),
                paneTitleAction: action
            )
        }

        if event.phase == .openDocument {
            guard !state.lifecycle.isEnded,
                event.executionState == nil,
                event.attentionReason == nil,
                event.state == nil,
                event.title == nil,
                let rawPath = event.documentPath,
                let documentPath = AgentRuntimeEvent.validatedDocumentPath(rawPath)
            else {
                return nil
            }
            recordApplied(
                dedupeKey: dedupeKey, timestamp: event.timestamp, now: now, into: &state
            )
            stateByPaneID[paneID] = state
            return Decision(
                update: WorkspaceAttentionReducer.SessionUpdate(),
                appliesPaneUpdate: false,
                documentPaneAction: .open(URL(fileURLWithPath: documentPath))
            )
        }

        // A new session restarts the lifecycle, so drop the post-exit latch.
        if event.phase == .sessionStart {
            let wasSessionEnded = state.lifecycle.isEnded
            let wasLifecycleStopped = state.lifecycle.currentIsStopped
            state.lifecycle.start()
            state.suppressesHeuristicState = false
            if event.source == .grok,
                (state.providerSessionID == nil || wasSessionEnded || wasLifecycleStopped),
                let providerSessionID = normalizedProviderSessionID(event.providerSessionID)
            {
                state.providerSessionID = providerSessionID
            }
        } else if event.phase == .stop {
            state.lifecycle.stop()
        } else if event.source == .grok,
            event.phase == .promptSubmit,
            state.providerSessionID == nil,
            let providerSessionID = normalizedProviderSessionID(event.providerSessionID)
        {
            state.providerSessionID = providerSessionID
        }

        let eventExecutionState =
            state.lifecycle.isEnded
            ? nil
            : event.executionState ?? event.state?.executionState
        // Once the pane has seen a session-exit reset, suppress any straggling
        // execution/attention from a buffered turn-end Stop until the next
        // session starts.
        // `.processError` is reserved for the internal sibling-pane-exit path
        // (WorkspaceAttentionReducer.recordPaneExitError), which co-fires a
        // specific VoiceOver announcement that the workspace attention tracker
        // then dedups against (INT-642). An event-file writer claiming it would
        // get its only announcement silently suppressed, so normalize it to
        // `.unknown` — behaviorally identical everywhere else (badge, restore).
        let rawAttentionReason =
            state.lifecycle.isEnded
            ? nil
            : event.attentionReason ?? event.state?.attentionReason
        let eventAttentionReason =
            rawAttentionReason == .processError
            ? .unknown
            : rawAttentionReason
        // Legacy `state` was a full display-state replacement, so an execution
        // update clears prior attention. Modern `executionState` is independent
        // and must not erase an explicit attention reason.
        let clearsAttention =
            event.attentionReason == nil
            && event.state?.executionState != nil
        // A fresh attention episode is either entering attention from none, or
        // a priority UPGRADE of a pending reason (.bell → .permissionPrompt):
        // the more urgent block deserves its own unread bump + banner even
        // though the pane was already loud (INT-506). Same/lower-priority
        // repeats stay silent.
        let enteringNeedsAttention: Bool
        if let eventAttentionReason {
            if let currentReason = currentPane.attentionReason {
                enteringNeedsAttention = eventAttentionReason.priority > currentReason.priority
            } else {
                enteringNeedsAttention = true
            }
        } else {
            enteringNeedsAttention = false
        }
        // A normal turn-end Stop is not an attention overlay anymore (INT-650):
        // it rests directly on .waiting so the sidebar shows the blue pause.
        // It is still an unread-worthy event when it happens outside the focused
        // terminal, so background completions keep producing badges/banners
        // without borrowing the peach `!` reserved for blocking decisions.
        let enteringUnseenTurnCompletion =
            event.phase == .stop
            && eventExecutionState == .waiting
            && eventAttentionReason == nil
        let unreadDelta =
            !terminalIsFocused
                && (enteringNeedsAttention || enteringUnseenTurnCompletion) ? 1 : 0

        let resolvedKind: AgentKind?
        if state.lifecycle.isEnded {
            // The agent has exited; don't let a late event re-infer its kind and
            // bring the glyph back. The kind stays whatever the reset left it.
            resolvedKind = nil
        } else if event.kind != nil {
            resolvedKind = event.kind
        } else if currentPane.agentKind == .shell {
            resolvedKind = event.source.inferredAgentKind
        } else {
            resolvedKind = nil
        }

        recordApplied(dedupeKey: dedupeKey, timestamp: event.timestamp, now: now, into: &state)
        stateByPaneID[paneID] = state

        return Decision(
            update: WorkspaceAttentionReducer.SessionUpdate(
                agentKind: resolvedKind,
                agentExecutionState: eventExecutionState,
                attentionReason: eventAttentionReason,
                clearsAttention: clearsAttention,
                unreadNotificationDelta: unreadDelta
            ))
    }

    /// Records an applied event into the per-pane state: appends its dedupe key
    /// (capacity-trimmed) and advances `lastAppliedTimestamp`. Shared by the
    /// state path and the rename path so both dedupe + order identically.
    private func recordApplied(
        dedupeKey: String?,
        timestamp: Date?,
        now: Date,
        into state: inout RuntimeEventState
    ) {
        if let dedupeKey {
            state.recentEventIDs.append(dedupeKey)
            if state.recentEventIDs.count > RuntimeEventState.recentEventIDCapacity {
                state.recentEventIDs.removeFirst(
                    state.recentEventIDs.count - RuntimeEventState.recentEventIDCapacity
                )
            }
        }
        advanceTimestampWatermark(timestamp, now: now, into: &state)
    }

    private func advanceTimestampWatermark(
        _ timestamp: Date?,
        now: Date,
        into state: inout RuntimeEventState
    ) {
        guard let timestamp else { return }
        state.lastAppliedTimestamp = max(
            state.lastAppliedTimestamp ?? .distantPast,
            min(timestamp, now)
        )
    }

    private func normalizedProviderSessionID(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func shouldDropGrokChildSessionEvent(
        _ event: AgentRuntimeEvent,
        state: RuntimeEventState
    ) -> Bool {
        guard event.source == .grok,
            let parentSessionID = state.providerSessionID,
            let eventSessionID = normalizedProviderSessionID(event.providerSessionID)
        else {
            return false
        }

        if event.phase == .sessionStart {
            if state.lifecycle.isEnded || state.lifecycle.currentIsStopped {
                return false
            }
        }

        return eventSessionID != parentSessionID
    }

    mutating func remove(paneID: TerminalPane.ID) {
        stateByPaneID[paneID] = nil
    }

    mutating func prune(livePaneIDs: Set<TerminalPane.ID>) {
        stateByPaneID = stateByPaneID.filter { livePaneIDs.contains($0.key) }
    }
}
