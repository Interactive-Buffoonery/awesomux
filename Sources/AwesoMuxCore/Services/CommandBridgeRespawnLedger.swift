/// Identity of one daemon incarnation behind a bridged session.
///
/// A respawn produces a *new* daemon (new pid + new creation timestamp); a
/// reconnect re-attaches to the *same* live daemon. Comparing the last-seen
/// incarnation against a freshly-attached one is how the attach client's
/// `attached` event tells "fresh daemon" from "reconnect" without trusting the
/// `created` flag alone (a respawn after a crash can race the flag).
public struct AmxDaemonIncarnation: Equatable, Sendable {
    public let pid: Int
    public let createdAt: Int
    /// Per-daemon random nonce. `attached` reports zero until the first typed
    /// foreground response supplies the daemon's nonce; older respawn-ledger
    /// fixtures may also omit it.
    public let incarnation: UInt64

    public init(pid: Int, createdAt: Int, incarnation: UInt64 = 0) {
        self.pid = pid
        self.createdAt = createdAt
        self.incarnation = incarnation
    }
}

/// Pure state machine for the per-pane respawn budget and daemon-incarnation
/// tracking that the AppKit exit-supervision path drives.
///
/// Mirrors `BridgeSessionEndPolicy`: the bookkeeping lives here, value-typed and
/// unit-testable, so the `NSView` stays a thin enactor. The view holds one of
/// these per pane, mutates it on watcher events / exit decisions, and reads the
/// decided action back out.
public struct CommandBridgeRespawnLedger: Equatable {
    /// Default ceiling on respawn/reconnect attempts before the supervision
    /// path latches `.error`. Bounds respawn storms against a daemon that dies
    /// the instant it comes back; `BridgeSessionEndPolicy.decide` takes this as
    /// `maxAttempts`. Lives next to the budget it caps.
    public static let defaultMaxRespawnAttempts = 3

    /// Number of respawn attempts spent since the budget was last refilled.
    /// `refillBudget()` resets all attempts after a fresh incarnation survives
    /// a grace window. A reconnect refunds only attempts still awaiting an
    /// attach outcome; attempts locked in by a fresh attach remain spent.
    ///
    /// This distinction is load-bearing: a crash-looping daemon emits an
    /// `attached` event on every respawn (that is what a respawn IS), so
    /// resetting on attach would oscillate the counter 0→1→0→1 and the cap
    /// would never be reached — the bounded-respawn guarantee would be a no-op.
    /// Gating the refill on proven uptime is what makes `.error` reachable for a
    /// daemon that dies the instant it comes back.
    public private(set) var respawnAttempts: Int = 0

    /// Attempts still waiting for an attach event to prove whether they spawned
    /// a fresh daemon or merely reconnected to the existing one.
    private var respawnAttemptsAwaitingAttachOutcome = 0

    /// The most recently attached daemon incarnation, or nil before the first
    /// attach. Consumed to distinguish a fresh respawn from a live reconnect.
    public private(set) var lastIncarnation: AmxDaemonIncarnation?

    public init(respawnAttempts: Int = 0, lastIncarnation: AmxDaemonIncarnation? = nil) {
        self.respawnAttempts = respawnAttempts
        self.lastIncarnation = lastIncarnation
    }

    /// Result of recording an `attached` event: whether the daemon behind the
    /// session is a *fresh* incarnation (respawn) versus the same one we last
    /// saw (reconnect). The caller fires the chrome-clear hook only on `.fresh`.
    public enum AttachOutcome: Equatable {
        /// First-ever attach for this pane. Treated as not-fresh: there is no
        /// prior chrome to clear.
        case firstAttach
        /// Same daemon as last time — a live reconnect; nothing to clear.
        case reconnect
        /// A different daemon than last time — a respawn; chrome must be cleared.
        case fresh
    }

    /// Record an `attached` event: update the last-seen incarnation and report
    /// whether it is a fresh daemon (respawn) or the same live one (reconnect).
    ///
    /// A reconnect refunds unresolved attempts because the matching incarnation
    /// proves the daemon stayed alive. Fresh and first attaches retain them;
    /// their budget refill remains gated on proven uptime via `refillBudget()`
    /// because a crash-looping daemon attaches on every cycle.
    ///
    /// - Returns: Whether this attach is to a fresh daemon (respawn) or the
    ///   same live one (reconnect).
    @discardableResult
    public mutating func recordAttach(_ incarnation: AmxDaemonIncarnation) -> AttachOutcome {
        let outcome: AttachOutcome
        if let lastIncarnation {
            outcome = (lastIncarnation == incarnation) ? .reconnect : .fresh
        } else {
            outcome = .firstAttach
        }
        lastIncarnation = incarnation
        if respawnAttemptsAwaitingAttachOutcome > 0 {
            if outcome == .reconnect {
                respawnAttempts = max(0, respawnAttempts - respawnAttemptsAwaitingAttachOutcome)
            }
            respawnAttemptsAwaitingAttachOutcome = 0
        }
        return outcome
    }

    /// Refill the respawn budget. The enactor calls this only after a fresh
    /// incarnation has survived a grace window — i.e. the session genuinely
    /// recovered, not just bounced through another doomed respawn. This is the
    /// counterweight to `recordRespawnAttempt`; without the uptime gate around
    /// it the cap is unreachable (see `respawnAttempts`).
    public mutating func refillBudget() {
        respawnAttempts = 0
        respawnAttemptsAwaitingAttachOutcome = 0
    }

    /// Spend one respawn attempt. Called when the exit-supervision path decides
    /// to `.respawnFresh` after a daemon death / unknown end. NOT spent for a
    /// user-initiated `.detached` → `.reconnect`: detach is a normal lifecycle
    /// event, not crash recovery, so it must not erode the crash budget (a
    /// detach-happy user would otherwise latch `.error` on a healthy session).
    public mutating func recordRespawnAttempt() {
        respawnAttempts += 1
        respawnAttemptsAwaitingAttachOutcome += 1
    }

    /// Drop all bridge bookkeeping (pane re-pointed at a new session, or surface
    /// disposed). Returns the ledger to its just-initialized state.
    public mutating func reset() {
        respawnAttempts = 0
        respawnAttemptsAwaitingAttachOutcome = 0
        lastIncarnation = nil
    }
}

/// Returns whether incoming status events should be processed for a pane.
///
/// A pane with a latched error must be inert to further status events:
/// a stray or late `attached` line on the status file must not silently
/// un-error the pane (clearing agent chrome + false-announcing "Session
/// restarted") while the user is looking at an error state. The latch is
/// cleared only on the legitimate recovery path (the enactor's
/// `decideExitFromStatus` on `.respawnFresh`/`.reconnect`, or the async legacy
/// probe), which runs before any new status events arrive on the recycled pane.
public func shouldProcessCommandBridgeStatusEvents(errorLatched: Bool) -> Bool {
    !errorLatched
}
