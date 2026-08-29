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
        // Whether any event was ever applied on this pane. Timestamps are
        // optional on the wire, so `lastAppliedTimestamp != nil` cannot stand
        // in for this: a timestamp-less stream would otherwise read as
        // "nothing applied" forever.
        var hasAppliedEvent = false
        // Arrival-order lifecycle state complements timestamps: it suppresses
        // both post-exit Stop events and an old SessionEnd delivered after a
        // stopped lifecycle has been superseded in the same pane.
        var lifecycle = Lifecycle.active
        // A turn-end Stop landed and nothing has started new work since.
        // Narrower than `lifecycle`, which tracks the whole session: this
        // resets on every `promptSubmit`/`toolStart`, so it means "between
        // turns", not "session over".
        var isBetweenTurns = false
        var suppressesHeuristicState = false
        // The provider-native session id of the agent currently running in this
        // pane, latched at SessionStart (or the first prompt submit, for a
        // missed SessionStart) and cleared when that session ends. Grok uses it
        // to keep child-agent lifecycle events from flipping the parent tile;
        // every provider uses it to prove that a buffered SessionEnd belongs to
        // the session it would reset.
        var providerSessionID: String?
        // Exact identity of the session that just ended. The live latch above
        // must still clear on sessionEnd — a new lifecycle's first event may
        // carry no id, and inheriting the old one would make it look like the
        // previous session. This copy is what Open Agent Transcript uses once
        // the pane is a shell, and it is dropped on the next SessionStart.
        var lastEndedTranscriptIdentity: AgentTranscriptIdentity?
        // Kind of the session that just ended, even when that kind cannot form
        // a transcript identity (OpenCode, Grok). Open Agent Transcript uses
        // this only for copy: it must still name the agent after the pane is a
        // shell, not claim the session is unknown.
        var lastEndedAgentKind: AgentKind?
        /// A recent user-input attempt that may have answered a permission
        /// prompt before its hook arrived. Runtime-only; used to suppress a
        /// stale `PermissionRequest` raise (issue #404).
        var lastPermissionAnswerAttemptAt: Date?
    }

    /// How long a permission-answer attempt remains evidence against a late
    /// `PermissionRequest` hook. Kept separate from
    /// `VisibleTextAgentStateReducer.runtimeEventSuppressionWindow` — that gate
    /// is about viewport inference, not user-input ordering.
    static let permissionAnswerAttemptFreshnessWindow: TimeInterval = 5.0

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

    enum RecentLinkAction: Sendable, Equatable {
        case record(String)
    }

    struct Decision: Sendable {
        var update: WorkspaceAttentionReducer.SessionUpdate
        var appliesPaneUpdate: Bool
        var paneTitleAction: PaneTitleAction?
        var documentPaneAction: DocumentPaneAction?
        var recentLinkAction: RecentLinkAction?

        init(
            update: WorkspaceAttentionReducer.SessionUpdate,
            appliesPaneUpdate: Bool = true,
            paneTitleAction: PaneTitleAction? = nil,
            documentPaneAction: DocumentPaneAction? = nil,
            recentLinkAction: RecentLinkAction? = nil
        ) {
            self.update = update
            self.appliesPaneUpdate = appliesPaneUpdate
            self.paneTitleAction = paneTitleAction
            self.documentPaneAction = documentPaneAction
            self.recentLinkAction = recentLinkAction
        }
    }

    var stateByPaneID: [TerminalPane.ID: RuntimeEventState] = [:]

    func suppressesHeuristicState(for paneID: TerminalPane.ID) -> Bool {
        stateByPaneID[paneID]?.suppressesHeuristicState == true
    }

    /// The provider-native session id currently latched for a pane, if any.
    ///
    /// Runtime-only and deliberately so: it names the session running in that
    /// pane *now*. A durable "which session is this document" answer is
    /// `DocumentPane.agentTranscriptIdentity`, not this.
    func providerSessionID(for paneID: TerminalPane.ID) -> String? {
        stateByPaneID[paneID]?.providerSessionID
    }

    /// The exact session that ended in this pane, if this process still knows.
    ///
    /// Separate from the live latch: keeping that id across sessionEnd would
    /// let the next lifecycle inherit it. Nil after relaunch, and nil once a
    /// new SessionStart has begun.
    func lastEndedTranscriptIdentity(for paneID: TerminalPane.ID) -> AgentTranscriptIdentity? {
        stateByPaneID[paneID]?.lastEndedTranscriptIdentity
    }

    /// The kind of the session that ended in this pane, if this process still
    /// knows. Survives even when that kind has no transcript adapter, so the
    /// command can name OpenCode or Grok after exit instead of treating the
    /// pane as an unknown shell session.
    func lastEndedAgentKind(for paneID: TerminalPane.ID) -> AgentKind? {
        stateByPaneID[paneID]?.lastEndedAgentKind
    }

    mutating func recordPermissionAnswerAttempt(
        paneID: TerminalPane.ID,
        now: Date
    ) {
        var state = stateByPaneID[paneID] ?? RuntimeEventState()
        state.lastPermissionAnswerAttemptAt = now
        stateByPaneID[paneID] = state
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
            // Full-rebuild pruning and explicit pane closure own cleanup. A
            // stale session lookup during a cross-workspace move must not erase
            // the still-live pane's runtime state.
            return nil
        }

        // First sight of a pane seeds `isBetweenTurns` from the pane's own
        // persisted execution state. The reducer's state is in-memory and rebuilt
        // empty on relaunch, but a restored pane at `.waiting` IS between turns —
        // without this seed, the first straggling `.toolEnd` from a job that
        // outlived the quit reproduces the exact bug the flag exists to stop.
        // Seeding only ever suppresses, so an over-broad `.waiting` (heuristic or
        // scraped) fails safe.
        var state =
            stateByPaneID[paneID]
            ?? RuntimeEventState(isBetweenTurns: currentPane.agentExecutionState == .waiting)
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
        // and, if it has its own awesomux status hooks installed, writes its own
        // lifecycle events into this pane's stream (confirmed live — see Task 2
        // background). A bare SessionStart is not enough to prove a genuine
        // foreground handoff: a nested child process fires its own SessionStart
        // too, while the pane's real established agent is still `.active`
        // mid-turn. Only trust a different-kind SessionStart once the established
        // agent's own tracked lifecycle shows it has stopped or fully ended — i.e.
        // it's between turns or gone, not mid-turn. Everything else from a
        // different provider is rejected outright, before it can touch dedupe,
        // staleness, or lifecycle state for the pane's real agent.
        //
        // That rejection applies ONLY when the incumbent kind was proven by
        // this pane's own runtime stream. A kind guessed from scraped viewport
        // text (e.g. a "claude code" string sitting in scrollback of a fresh
        // OpenCode pane) carries no such proof — rejecting the real agent's
        // events forever made one stray substring permanently mislabel the
        // pane, surviving relaunch through persistence. A text-guessed kind
        // therefore yields to a genuine identity boundary (session start or
        // user prompt) from another provider; foreign tool-lifecycle chatter
        // still cannot steal the pane.
        // A text-guessed kind may yield to a foreign identity boundary only
        // while the guessed provider's own stream shows no live turn. A nested
        // child of a DIFFERENT provider can fire `.promptSubmit` into this
        // pane's event file while the real (text-guessed) agent works; taking
        // it mid-turn would steal the pane, mark the child's kind
        // runtime-proven, and leave the parent's genuine events failing the
        // cross-provider guard forever. An unproven guess
        // (`hasAppliedEvent == false`) stays reclaimable — the stray-
        // scrollback case above — and a stopped or ended lifecycle clears the
        // live-turn test the same way it clears the runtime-proven exception.
        //
        // The yield is also refused when the boundary PROVES itself foreign.
        // The session-id latch survives a mid-turn text retag (only sessionEnd
        // clears it), so when both sides carry ids and they disagree, this is
        // the same proof the sessionEnd path below already acts on: the event
        // belongs to some other session than the one running in this pane, and
        // no quiet turn boundary makes it the real agent. A nested child firing
        // its own boundary while the real agent idles between applied turns is
        // refused here rather than stealing the kind and its proof. An id-less
        // boundary stays unproven and remains governed by the live-turn test
        // alone, exactly as unproven ends remain governed by the lifecycle
        // shape. The ended/stopped restart bypasses all of this by design —
        // between turns, a different id IS how a user-launched replacement
        // announces itself.
        //
        // Only the `.promptSubmit` half of the boundary test carries behavioral
        // weight. A `.sessionStart` bypassing the restart clause above implies
        // the lifecycle is neither ended nor stopped, and a non-nil session-id
        // latch implies an applied event, so `incumbentShowsLiveTurn` already
        // refuses it; the `.sessionStart` arm stays as defense in depth should
        // the latch-without-applied-event state ever become reachable (e.g. a
        // future persistence change).
        let incumbentShowsLiveTurn =
            state.hasAppliedEvent
            && !state.lifecycle.currentIsStopped
            && !state.lifecycle.isEnded
        let boundaryProvesForeignSession =
            (event.phase == .sessionStart || event.phase == .promptSubmit)
            && idsProveAnotherSession(event.providerSessionID, latched: state.providerSessionID)
        if let eventKind = event.kind,
            currentPane.agentKind != .shell,
            currentPane.agentKind != eventKind,
            !(event.phase == .sessionStart && (state.lifecycle.isEnded || state.lifecycle.currentIsStopped)),
            currentPane.agentKindIsRuntimeEstablished
                || !(event.phase == .sessionStart || event.phase == .promptSubmit)
                || incumbentShowsLiveTurn
                || boundaryProvesForeignSession
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
            // Identity, not lifecycle shape, decides whether an end belongs to
            // the session it would reset. Two rules, because they fail in
            // opposite directions:
            //
            // - Two ids that DISAGREE prove the end came from some other
            //   session — a buffered end from the pane's previous agent, or a
            //   nested same-kind child (`claude -p` inside a Bash tool call)
            //   exiting mid-turn. Drop it whatever the lifecycle says. Gating
            //   the whole check on superseded-but-not-stopped left
            //   `.supersededStopped` open: once the superseding session emitted
            //   its own turn-end Stop the check switched itself off, and the
            //   next stale end reset a live agent to `.shell` — mid-turn, if
            //   that session had since submitted another prompt (cross-model
            //   review).
            // - An UNPROVEN end (either side missing an id) stays gated on
            //   superseded-but-not-stopped, i.e. a new session is latched AND
            //   working. Widening it to `.supersededStopped` too would break
            //   every provider that reports no id at all: for them the ordinary
            //   "second session in this pane quits" is unproven by
            //   construction, and refusing it strands the agent glyph forever.
            //   The `.supersededStopped` hole is closed by the rule above
            //   instead, which needs no lifecycle shape — and once both sides
            //   carry ids, which is the whole point of latching them, that is
            //   the rule that fires.
            let latchedSessionID = normalizedProviderSessionID(state.providerSessionID)
            let eventSessionID = normalizedProviderSessionID(event.providerSessionID)
            let isProvablyThisSession =
                latchedSessionID != nil && latchedSessionID == eventSessionID
            let isProvablyAnotherSession =
                latchedSessionID != nil && eventSessionID != nil && !isProvablyThisSession
            let isUnprovenEndOverALiveSession =
                state.lifecycle.hasSupersededLifecycle
                && !state.lifecycle.currentIsStopped
                && !isProvablyThisSession
            if isProvablyAnotherSession || isUnprovenEndOverALiveSession {
                return nil
            }
            state.lifecycle = .ended
            state.suppressesHeuristicState =
                state.suppressesHeuristicState
                || event.source.hasTrustworthySessionRestartBoundary
            // The session this id identified is over. Holding it on the live
            // latch would let the next lifecycle — whose first event may carry
            // no id at all — report the previous session as its own. Keep the
            // exact identity separately so Open Agent Transcript can still
            // resolve that file after the pane becomes a shell. Keep the kind
            // even when no identity can be formed, so an OpenCode or Grok pane
            // still names itself after exit.
            let kind =
                currentPane.agentKind == .shell
                ? (event.source.inferredAgentKind ?? .shell)
                : currentPane.agentKind
            state.lastEndedAgentKind = kind == .shell ? nil : kind
            if let sessionID = state.providerSessionID {
                state.lastEndedTranscriptIdentity = AgentTranscriptIdentity(
                    agentKind: kind,
                    sessionID: sessionID
                )
            }
            state.providerSessionID = nil
            advanceTimestampWatermark(event.timestamp, now: now, into: &state)
            stateByPaneID[paneID] = state
            return Decision(
                update: WorkspaceAttentionReducer.SessionUpdate(
                    agentKind: .shell,
                    agentKindIsRuntimeEstablished: false,
                    agentExecutionState: event.executionState ?? .idle,
                    clearsAttention: true,
                    // The agent that raised the prompt is gone, so nothing can
                    // answer it anymore — this is a resolution, not an inference
                    // from quiet output, and it clears a pending prompt the same
                    // way it already clears the unread badge.
                    attentionClearIsAuthoritative: true,
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
            // Drop the old id BEFORE latching: a proven new lifecycle whose
            // SessionStart carries no id must report "unknown session", never
            // the previous session's id.
            //
            // A same-kind SessionStart carrying a DIFFERENT id while the
            // lifecycle still reads active is modelled here rather than left to
            // fall through the latch guard below, because the two things it can
            // be pull in opposite directions:
            //
            // - a nested `claude -p` inside a Bash tool call, which must NOT
            //   move the latch (see the top of this function);
            // - a genuine handoff — a `/clear`-style restart, or a fresh agent
            //   launched after the previous one died without writing Stop or
            //   SessionEnd (kill -9, crash, sleep) — which must.
            //
            // `isBetweenTurns` separates them: a nested child can only be
            // spawned FROM a tool call, so its SessionStart always lands
            // mid-turn, while a user typing at a returned prompt never does.
            // It is a superset of "not in a tool call", so it errs toward
            // keeping the parent's id, the safe direction. Getting this wrong
            // is no longer just a stale equality check: the latched id is now a
            // filesystem lookup and a staged resume command.
            //
            // Note: `AgentLivenessPolicy` covers the common unclean death
            // by synthesizing an id-less `sessionEnd`, which clears the latch
            // outright. The residual gap is a pane that has already superseded
            // once and is killed MID-turn: that synthetic end is dropped as
            // unproven, and neither signal here fires, so the dead id survives
            // until the next clean lifecycle. Revisit if the app ever hands the
            // reducer a liveness signal it can trust on its own.
            if wasSessionEnded || wasLifecycleStopped || state.isBetweenTurns {
                state.providerSessionID = nil
                state.lastEndedTranscriptIdentity = nil
                state.lastEndedAgentKind = nil
            }
            if state.providerSessionID == nil,
                let providerSessionID = normalizedProviderSessionID(event.providerSessionID)
            {
                state.providerSessionID = providerSessionID
            }
        } else if event.phase == .stop {
            state.lifecycle.stop()
        } else if event.phase == .promptSubmit,
            state.providerSessionID == nil,
            let providerSessionID = normalizedProviderSessionID(event.providerSessionID)
        {
            state.lastEndedTranscriptIdentity = nil
            state.lastEndedAgentKind = nil
            state.providerSessionID = providerSessionID
        }

        // Turn-boundary tracking for the trailing-`.toolEnd` suppression below.
        // Exhaustive on purpose: a phase added to `AgentRuntimePhase` later must
        // be a compile error here, not silently inherit "does not end a turn" —
        // that inheritance is the exact shape of the bug this flag fixes. The
        // `.stop`/`.sessionStart` arms duplicate a phase test from the lifecycle
        // chain above; keep the two in sync.
        switch event.phase {
        case .stop:
            state.isBetweenTurns = true
        case .notification:
            // Claude Code's idle-prompt Notification asserts `.waiting` and is
            // turn-end evidence of the same grade as a Stop; its other subtypes
            // (permission prompt, input required) are not.
            state.isBetweenTurns =
                state.isBetweenTurns || event.assertsWaitingExecutionState
        case .sessionStart, .promptSubmit, .toolStart:
            state.isBetweenTurns = false
        case .toolEnd, .sessionEnd, .rename, .openDocument, .permissionReplied, nil:
            break
        }

        // A tool-lifecycle END that lands after the turn already ended belongs
        // to work that STARTED before the Stop — a background Bash task, or a
        // subagent (`SubagentStop` maps to `.toolEnd`) finishing on its own
        // schedule seconds to minutes later. It reports that a tool finished,
        // never that the agent went back to work; only `toolStart` and
        // `promptSubmit` do that. Letting it assert `.thinking` downgraded a
        // genuinely receptive pane out of `.waiting`, killing the sidebar's
        // needs-input row and the document pane's send button until the next
        // turn or Claude Code's ~60s idle Notification re-confirmed waiting.
        // Observed live in a single-provider trace (stop at t, toolEnd at t+2.2s
        // and again at t+3min).
        //
        // ponytail: this closes the trailing-END half only. A background
        // producer's `.toolStart` after a Stop still clears the flag and asserts
        // `.thinking` — measured at 11 of 32 turn-ends in a 4588-event trace,
        // because subagent tool calls inherit the pane's event file. Discriminating
        // a background producer needs a payload signal the wire protocol does not
        // carry yet; revisit when it does (tracked separately). Widening this to
        // `.toolStart` without that signal would let a hook-forced continuation
        // read `.waiting` while the agent is genuinely mid-render — the direction
        // this gate must never fail in.
        let ignoresTrailingToolEnd = state.isBetweenTurns && event.phase == .toolEnd

        let eventExecutionState =
            state.lifecycle.isEnded || ignoresTrailingToolEnd
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
        // An explicit attention reason survives the trailing-`.toolEnd`
        // suppression: no bundled provider puts one on a `.toolEnd` today, but the
        // event file is a documented protocol and the bridge forwards the pairing
        // unchanged, so dropping it would silently swallow a real blocking prompt.
        // Only the event's claim about *execution* is unreliable here.
        let rawAttentionReason =
            state.lifecycle.isEnded
            ? nil
            : event.attentionReason ?? event.state?.attentionReason
        let eventAttentionReason =
            rawAttentionReason == .processError
            ? .unknown
            : rawAttentionReason
        let effectiveAttentionReason: AttentionReason?
        if eventAttentionReason == .permissionPrompt,
            let attemptAt = state.lastPermissionAnswerAttemptAt,
            now.timeIntervalSince(attemptAt) <= Self.permissionAnswerAttemptFreshnessWindow
        {
            // The user already answered in the TUI before this hook landed.
            effectiveAttentionReason = nil
        } else {
            effectiveAttentionReason = eventAttentionReason
        }
        if effectiveAttentionReason == .permissionPrompt {
            state.lastPermissionAnswerAttemptAt = nil
        }
        // Legacy `state` was a full display-state replacement, so an execution
        // update clears prior attention. Modern `executionState` is independent
        // and must not erase an explicit attention reason.
        // An ignored event must not CLEAR attention either — its execution claim
        // is what a legacy full-`state` event would clear on, and that claim is
        // precisely what the suppression rejects.
        let clearsAttention =
            !ignoresTrailingToolEnd
            && event.attentionReason == nil
            && event.state?.executionState != nil
        // A fresh attention episode is either entering attention from none, or
        // a priority UPGRADE of a pending reason (.bell → .permissionPrompt):
        // the more urgent block deserves its own unread bump + banner even
        // though the pane was already loud (INT-506). Same/lower-priority
        // repeats stay silent.
        let enteringNeedsAttention: Bool
        if let effectiveAttentionReason {
            if let currentReason = currentPane.attentionReason {
                enteringNeedsAttention = effectiveAttentionReason.priority > currentReason.priority
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
            && effectiveAttentionReason == nil
        let unreadDelta =
            !terminalIsFocused
                && (enteringNeedsAttention || enteringUnseenTurnCompletion) ? 1 : 0
        // A prompt submission is the agent's own confirmation that a reply
        // reached this pane — typed by the user or delivered out-of-band via
        // `amx send` — so it retires what the pane accumulated while the user
        // was away: the unread badge and any pending attention reason,
        // including one that `awaitsExplicitAnswer` (redirecting the agent
        // moots the raised question). OpenCode/Codex/Pi turn-ends rest on
        // quiet `.waiting` with no attention reason, so the badge such a
        // turn-end raises previously had no clear path short of SessionEnd:
        // answering the agent left the badge stuck and every later background
        // turn-end ratcheted it higher. This is the event-path equivalent of
        // `markNeedsAttentionPromptAnswered`'s authoritative clear, which
        // keystroke routing only reaches for panes already projecting
        // `.needsAttention`.
        let answersPendingNotifications =
            event.phase == .promptSubmit
            && (normalizedProviderSessionID(event.providerSessionID).map {
                $0 == state.providerSessionID
            } ?? true)
        // A permission reply directly proves that the gate resolved. For
        // providers without that event, the first plain tool start afterward is
        // equivalent proof even when the answer went through the agent TUI
        // (mouse click) instead of awesoMux's keystroke path. A tool start that
        // carries its own attention reason is a new blocking claim, not a
        // retraction. Scoped to `.permissionPrompt` only — `.userInputRequired`
        // can still be live while background tool phases run (issue #404).
        //
        // Provider session IDs reject identifiable child sessions. Same-session
        // background producers remain indistinguishable on the v1 wire format,
        // so they retain the accepted false-clear window documented above.
        let eventMatchesProviderSession =
            !idsProveAnotherSession(event.providerSessionID, latched: state.providerSessionID)
        let resolvesPendingPermissionPrompt =
            currentPane.attentionReason == .permissionPrompt
            && eventMatchesProviderSession
            && (event.phase == .permissionReplied
                || (event.phase == .toolStart && eventAttentionReason == nil))
        if resolvesPendingPermissionPrompt {
            state.lastPermissionAnswerAttemptAt = nil
        }

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

        // An event that contributed NOTHING must not raise the staleness
        // watermark: hook events are appended by independent short-lived
        // processes that sample their own timestamps, so append order and
        // timestamp order can invert by microseconds. If an inert event advanced
        // the bar, the `.toolStart` that would have disarmed `isBetweenTurns`
        // could be dropped as stale — stranding the pane at `.waiting` for a
        // whole working turn, the one direction this must never fail in.
        //
        // This holds for EVERY suppressed `.toolEnd`, including one that still
        // delivered an attention reason or a touched path. Two reviews pulled in
        // opposite directions here and the tie breaks on which way each fails:
        //
        // - Holding it always (this) lets a suppressed event replay once the
        //   capacity-64 dedupe ring evicts its key, re-raising a prompt the user
        //   already resolved. Noisy, self-correcting, needs 64 intervening events.
        // - Advancing it for those events lets a `touchedPath` toolEnd — every
        //   background file write — stale-drop a `.toolStart` sampled microseconds
        //   earlier. `isBetweenTurns` then never clears, every later `.toolEnd`
        //   stays suppressed, and the pane reads `.waiting` for a whole working
        //   turn with the send bar armed into a live composer. Timestamp
        //   inversions were measured at 0.6% of real events.
        //
        // The second is the direction this gate exists to prevent, so it loses.
        let contributedNothing =
            ignoresTrailingToolEnd
            || (event.phase == .permissionReplied && !resolvesPendingPermissionPrompt)
        recordApplied(
            dedupeKey: dedupeKey,
            timestamp: contributedNothing ? nil : event.timestamp,
            now: now,
            into: &state
        )
        stateByPaneID[paneID] = state

        // A Claude Code tool just wrote/edited a Markdown file (issue #175).
        // Surfacing it here — on the post-guard main return, so it inherits the
        // dedupe/staleness/lifecycle drops above — records the untruncated path
        // into the pane's recent links even though the agent's own console
        // output hard-wrapped it beyond any link matcher's reach. Suppressed
        // once the lifecycle has ended so a straggling tool event from a quit
        // agent cannot seed the palette.
        let recentLinkAction: RecentLinkAction? =
            !state.lifecycle.isEnded
            ? event.touchedPath.map { .record($0) }
            : nil

        return Decision(
            update: WorkspaceAttentionReducer.SessionUpdate(
                agentKind: resolvedKind,
                // Any kind this stream emits is runtime-proven by definition,
                // whether it just claimed a shell pane or reclaimed one a
                // viewport scrape had mislabeled.
                agentKindIsRuntimeEstablished: resolvedKind != nil ? true : nil,
                agentExecutionState: eventExecutionState,
                attentionReason: effectiveAttentionReason,
                clearsAttention:
                    clearsAttention
                    || answersPendingNotifications
                    || resolvesPendingPermissionPrompt,
                attentionClearIsAuthoritative:
                    answersPendingNotifications
                    || resolvesPendingPermissionPrompt,
                clearsUnreadNotifications:
                    answersPendingNotifications
                    || resolvesPendingPermissionPrompt,
                unreadNotificationDelta: unreadDelta
            ),
            recentLinkAction: recentLinkAction)
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
        state.hasAppliedEvent = true
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

    /// True when both sides carry ids and they disagree — proof, per the
    /// sessionEnd rule below, that the event belongs to some other session
    /// than the one latched for this pane. A missing id on either side stays
    /// unproven and leaves the decision to the caller's other gates.
    private func idsProveAnotherSession(
        _ eventSessionID: String?,
        latched latchedSessionID: String?
    ) -> Bool {
        let eventID = normalizedProviderSessionID(eventSessionID)
        let latchedID = normalizedProviderSessionID(latchedSessionID)
        return eventID != nil && latchedID != nil && eventID != latchedID
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
