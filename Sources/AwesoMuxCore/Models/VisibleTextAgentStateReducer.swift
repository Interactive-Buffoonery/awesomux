import Foundation

public enum AgentStateAnnouncementIntent: Equatable, Sendable {
    case errorEntered
    case errorCleared
    case errorClearedAndWaiting
    case waitingEntered
    case none

    /// Whether the transition that produced this intent should also drop the
    /// stale-error latch. Kept on the enum so the detector path and the
    /// runtime-event path can't drift on which intents clear it.
    public var clearsStaleError: Bool {
        self == .errorCleared || self == .errorClearedAndWaiting
    }
}

public struct VisibleTextAgentStateReducer: Sendable {
    public struct Decision: Equatable, Sendable {
        public var shouldApply: Bool
        public var shouldApplyState: Bool
        public var agentKind: AgentKind?
        public var clearsAttention: Bool
        public var clearsUnreadNotifications: Bool
        public var unreadNotificationDelta: Int
        public var announcementIntent: AgentStateAnnouncementIntent
        public var shouldClearStaleError: Bool

        public init(
            shouldApply: Bool,
            shouldApplyState: Bool? = nil,
            agentKind: AgentKind? = nil,
            clearsAttention: Bool = false,
            clearsUnreadNotifications: Bool = false,
            unreadNotificationDelta: Int = 0,
            announcementIntent: AgentStateAnnouncementIntent = .none,
            shouldClearStaleError: Bool = false
        ) {
            self.shouldApply = shouldApply
            self.shouldApplyState = shouldApplyState ?? shouldApply
            self.agentKind = agentKind
            self.clearsAttention = clearsAttention
            self.clearsUnreadNotifications = clearsUnreadNotifications
            self.unreadNotificationDelta = unreadNotificationDelta
            self.announcementIntent = announcementIntent
            self.shouldClearStaleError = shouldClearStaleError
        }
    }

    public struct RuntimeEventSuppressionDecision: Equatable, Sendable {
        public var shouldRecordStateEvent: Bool
        public var shouldRecordAttentionEvent: Bool

        public init(shouldRecordStateEvent: Bool, shouldRecordAttentionEvent: Bool) {
            self.shouldRecordStateEvent = shouldRecordStateEvent
            self.shouldRecordAttentionEvent = shouldRecordAttentionEvent
        }
    }

    /// How long visible-text fallback should yield after an explicit runtime
    /// event updates agent state. This protects side-channel state from stale
    /// viewport samples. It is currently also `2.0` seconds like
    /// `CommandExitCache.defaultFreshnessWindow`, but that cache attributes a
    /// near-immediate Ghostty command-finished callback to a later process-exit
    /// close callback; keep the constants separate so tuning one race window
    /// does not silently tune the other.
    public static let runtimeEventSuppressionWindow: TimeInterval = 2.0

    public init() {}

    /// Whether `sampleAgentStateFromVisibleText` should run the (expensive)
    /// `AgentOutputDetector` scan at all. When a reliable-hook agent has a
    /// fresh runtime event, `shouldSuppressVisibleTextState` would discard any
    /// non-attention result AND `blockedByReliableHook` discards
    /// `.needsAttention` too — so the ~59-substring scan is provably wasted
    /// work. The raw visible-text READ and diff still run for every pane:
    /// VoiceOver's value-changed announcement and quit-risk activity marking
    /// ride that diff.
    public static func shouldRunVisibleTextDetector(
        now: TimeInterval,
        lastRuntimeEventAppliedAt: TimeInterval?,
        liveAgentKind: AgentKind
    ) -> Bool {
        guard liveAgentKind.usesReliableHooks,
            liveAgentKind.usesReliableAttentionHooks,
            let lastRuntimeEventAppliedAt
        else {
            return true
        }
        return now - lastRuntimeEventAppliedAt >= runtimeEventSuppressionWindow
    }

    public func shouldSuppressVisibleTextState(
        detectedState: AgentState,
        now: TimeInterval,
        lastRuntimeEventAppliedAt: TimeInterval?,
        lastRuntimeAttentionEventAppliedAt: TimeInterval?,
        liveDisplayState: AgentState?
    ) -> Bool {
        guard let lastRuntimeEventAppliedAt,
              now - lastRuntimeEventAppliedAt < Self.runtimeEventSuppressionWindow else {
            return false
        }

        if detectedState == .needsAttention {
            if let lastRuntimeAttentionEventAppliedAt,
               now - lastRuntimeAttentionEventAppliedAt < Self.runtimeEventSuppressionWindow {
                return true
            }

            guard let liveDisplayState else {
                return false
            }
            return liveDisplayState.isAtLeastAsUrgent(as: detectedState)
        }

        return true
    }

    public func visibleTextDecision(
        detectedState: AgentState,
        detectedAgentKind: AgentKind?,
        detectedKindIsAuthoritative: Bool = false,
        liveAgentKind: AgentKind,
        liveExecutionState: AgentExecutionState,
        liveDisplayState: AgentState,
        terminalIsActiveForAttention: Bool
    ) -> Decision {
        let agentKind = agentKindCorrection(
            detectedAgentKind: detectedAgentKind,
            detectedKindIsAuthoritative: detectedKindIsAuthoritative,
            liveAgentKind: liveAgentKind
        )
        let shouldApplyState = shouldApplyVisibleTextState(
            detectedState: detectedState,
            liveAgentKind: liveAgentKind,
            liveExecutionState: liveExecutionState,
            liveDisplayState: liveDisplayState
        )
        guard shouldApplyState || agentKind != nil else {
            return Decision(shouldApply: false)
        }
        guard shouldApplyState else {
            return Decision(shouldApply: true, shouldApplyState: false, agentKind: agentKind)
        }

        let announcementIntent = announcementIntent(
            priorDisplayState: liveDisplayState,
            newDisplayState: detectedState
        )
        let detectedNeedsAttention = detectedState == .needsAttention
        let clearsUnreadNotifications = liveDisplayState == .needsAttention
            && !detectedNeedsAttention
            && terminalIsActiveForAttention

        return Decision(
            shouldApply: true,
            agentKind: agentKind,
            clearsAttention: !detectedNeedsAttention,
            clearsUnreadNotifications: clearsUnreadNotifications,
            unreadNotificationDelta: detectedNeedsAttention && !terminalIsActiveForAttention
                ? 1
                : 0,
            announcementIntent: announcementIntent,
            shouldClearStaleError: announcementIntent.clearsStaleError
        )
    }

    public func visibleTextDecision(
        detectedState: AgentState,
        liveExecutionState: AgentExecutionState,
        liveDisplayState: AgentState,
        terminalIsActiveForAttention: Bool
    ) -> Decision {
        visibleTextDecision(
            detectedState: detectedState,
            detectedAgentKind: nil,
            liveAgentKind: .shell,
            liveExecutionState: liveExecutionState,
            liveDisplayState: liveDisplayState,
            terminalIsActiveForAttention: terminalIsActiveForAttention
        )
    }

    public func agentKindCorrection(
        detectedAgentKind: AgentKind?,
        detectedKindIsAuthoritative: Bool = false,
        liveAgentKind: AgentKind
    ) -> AgentKind? {
        guard let detectedAgentKind, detectedAgentKind != liveAgentKind else {
            return nil
        }
        // Text may claim an unidentified shell for any agent. It may also
        // correct a stale hook-set `.codex` — but ONLY from confident Claude
        // cues (the original stale-identity case). Grok's prompt signature is
        // fragile, so it must never override an already hook-identified agent
        // (that mislabelled starting Codex sessions as Grok); it can still
        // light up a bare shell before the first Grok hook lands.
        if liveAgentKind == .shell {
            return detectedAgentKind
        }
        if detectedKindIsAuthoritative, detectedAgentKind.usesReliableHooks {
            return detectedAgentKind
        }
        if liveAgentKind == .codex, detectedAgentKind == .claudeCode {
            return detectedAgentKind
        }
        return nil
    }

    public func shouldApplyVisibleTextState(
        detectedState: AgentState,
        liveAgentKind: AgentKind,
        liveExecutionState: AgentExecutionState,
        liveDisplayState: AgentState
    ) -> Bool {
        guard detectedState != .waiting else {
            // Text → waiting is normally forbidden (ADR-0007): waiting requires
            // an explicit runtime Stop. Grok Build 0.2.x never fires those hooks,
            // so without this carve-out a Grok pane that entered `.thinking` via
            // viewport cues can never leave until the process dies. Allow
            // identity-only waiting to clear sticky thinking for Grok only.
            if liveAgentKind == .grok,
               (liveDisplayState == .thinking || liveExecutionState == .thinking) {
                return liveDisplayState != .waiting
            }
            return false
        }
        guard liveDisplayState != detectedState else {
            return false
        }
        // A hook-driven agent owns its own lifecycle: never let a `.done` or a
        // `.needsAttention` from the visible-text path reach the tile.
        //
        // `.done` covers both callers — a scraped `.done` (matched anywhere in
        // the viewport, e.g. a subagent's "task complete" transcript line) AND
        // a command-finished exit-0 `.done` (`handleCommandFinished` →
        // `applyDetectedAgentState(.done)` routes here too). The hook stream
        // reports the real turn-end (`.waiting`) and SessionEnd; if a hook is
        // dropped, the passive idle-shell detector is the backstop.
        //
        // `.needsAttention` (INT-714): providers with reliable attention hooks
        // report real permission prompts through the side channel, so a scraped
        // attention cue — e.g. a subagent's `[y/n] proceed?` transcript line
        // rendered in the shared pane — is only a false positive that arms the
        // Acknowledge banner while the parent agent is still driving. Pi and
        // Grok keep the scrape because their installed integrations do not
        // currently report blocking attention (Grok 0.2.x never runs plugin
        // Permission hooks).
        //
        // Scoped to these two states, so an exit-nonzero `.error` still
        // applies. See AgentKind.usesReliableHooks.
        let blockedByReliableHook = detectedState == .done
            ? liveAgentKind.usesReliableHooks
            : detectedState == .needsAttention && liveAgentKind.usesReliableAttentionHooks
        guard !blockedByReliableHook else {
            return false
        }

        guard liveExecutionState == .waiting else {
            return true
        }

        switch detectedState {
        case .idle, .running, .waiting:
            return false
        case .thinking, .output, .needsAttention, .done, .error:
            return true
        }
    }

    public func announcementIntent(
        priorDisplayState: AgentState?,
        newDisplayState: AgentState?
    ) -> AgentStateAnnouncementIntent {
        guard let newDisplayState, newDisplayState != priorDisplayState else {
            return .none
        }
        if newDisplayState == .error {
            return .errorEntered
        }
        if priorDisplayState == .error, newDisplayState != .needsAttention {
            // error → waiting speaks BOTH facts in one combined announcement
            // (mirrors the errorClearedAndShellRecycled precedent): the user
            // needs "error's gone" AND "your turn" — checked before the generic
            // cleared branch or the waiting half would be silently swallowed.
            return newDisplayState == .waiting ? .errorClearedAndWaiting : .errorCleared
        }
        if newDisplayState == .waiting {
            return .waitingEntered
        }
        return .none
    }

    public func runtimeEventSuppressionDecision(
        state: AgentState?,
        executionState: AgentExecutionState?,
        attentionReason: AttentionReason?
    ) -> RuntimeEventSuppressionDecision {
        let shouldRecordStateEvent = state != nil
            || executionState != nil
            || attentionReason != nil
        let shouldRecordAttentionEvent = state == .needsAttention
            || attentionReason != nil
        return RuntimeEventSuppressionDecision(
            shouldRecordStateEvent: shouldRecordStateEvent,
            shouldRecordAttentionEvent: shouldRecordAttentionEvent
        )
    }
}
