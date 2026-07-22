import Foundation

/// The shared invariant core of the `permission-request` lifecycle
/// (spec's "Permission lifecycle" section): an id-keyed map of outstanding
/// requests, capped, with first-terminal-event-wins resolution. Both sides
/// of the bridge need this exact bookkeeping — the helper (its own
/// `pendingRequests` map) and the app (its independent app-side twin cap +
/// timer) — so it lives once here rather than as two hand-mirrored
/// implementations that could drift apart on the cap or the atomicity rule.
///
/// **Deliberately narrow, by review-gate decision — this type does NOT
/// contain:**
/// - **Confused-deputy target binding** (checking a `permission-decision`'s
///   `inReplyTo` *and* `target` against the entry it names before accepting
///   it) — that's a helper-side wrapper's job (task B2). `peek(id:)` exists
///   so that wrapper can read the submitted target *without* consuming the
///   entry (a mismatched decision must leave the legitimate entry pending,
///   per the spec's "discarded, never applied"); the comparison itself and
///   what to do on mismatch stay in the wrapper.
/// - **`permission-resolved` frame emission** — `sweepExpired`/`drainAll`
///   return the entries that need one, but building and writing the wire
///   frame is the wrapper's job (task B2).
/// - **FIFO presentation, the 120 s app-side clamp, or `scope: session`
///   grant bookkeeping** — all app-wrapper policy (task E1). This map
///   doesn't know which request is "presented" vs "queued", doesn't apply
///   the clamp to `expiresAt` (callers pass whatever deadline they've
///   already decided on), and doesn't remember granted scopes past a
///   resolution.
///
/// Value type: a pure, `Sendable`-friendly struct with mutating methods —
/// there's no shared mutable state or actor isolation concern here, so a
/// class (with the identity/aliasing questions that come with it) would be
/// an unrequested abstraction for what is otherwise a dictionary with rules.
///
/// **Caller contract — one authoritative instance.** Value semantics mean a
/// copy is an independent map: first-terminal-event-wins holds *within* one
/// instance, and a terminal event applied to a copy does nothing to the
/// original. The owning wrapper (B2's helper loop, E1's app store) must
/// keep a single authoritative instance behind whatever serialization it
/// already has and never resolve against a snapshot. `Sendable` here means
/// "safe to move between tasks", not "shared".
public struct BridgePendingRequestMap: Sendable, Equatable {

    /// One outstanding `permission-request`. Carries its own `id` (not just
    /// the dictionary key) so a batch return from `sweepExpired`/`drainAll`
    /// is self-describing — a caller building `permission-resolved` frames
    /// needs each entry's id for `inReplyTo` without threading it through
    /// separately.
    public struct Entry: Sendable, Equatable {
        public let id: String
        public let target: String
        public let tool: String
        public let expiresAt: Date

        public init(id: String, target: String, tool: String, expiresAt: Date) {
            self.id = id
            self.target = target
            self.tool = tool
            self.expiresAt = expiresAt
        }
    }

    /// The four ways an entry can reach a terminal state, per the spec:
    /// "a valid `permission-decision` (applied, entry cleared), the deadline
    /// expiring ..., the agent abandoning the prompt (`agent-cancelled`), or
    /// the connection dying (`connection-lost`)."
    public enum TerminalEvent: Sendable, Equatable {
        case decisionApplied
        case expired
        case cancelled
        case connectionLost
    }

    public enum AdmitOutcome: Sendable, Equatable {
        case admitted(Entry)
        /// The map already holds `BridgeTunables.pendingRequestCap` entries;
        /// the new request is not stored and the pending entries are
        /// untouched.
        case overflow
        /// `id` already names a live entry; the existing entry is untouched.
        /// Request ids are peer-chosen (untrusted input), and silently
        /// overwriting a pending entry would corrupt the ground truth the
        /// confused-deputy `target` check (task B2) compares against — the
        /// user would have been shown one target while the map quietly held
        /// another. Checked before the cap so a duplicate at-cap reports as
        /// what it is, not as overflow.
        case duplicate
        /// `expiresAt` is non-finite (NaN/±infinity). Every ordered
        /// comparison against NaN is false, so an admitted NaN deadline
        /// could never expire — an immortal entry squatting the cap. JSON
        /// cannot encode non-finite numbers, so the wire can't produce this;
        /// the guard is against a caller bug, which is exactly when it must
        /// fail loudly rather than admit a zombie.
        case invalidDeadline
    }

    public enum ResolveOutcome: Sendable, Equatable {
        case resolved(Entry, TerminalEvent)
        /// Covers both "no entry was ever admitted under this id" and
        /// "an entry existed but a prior terminal event already cleared
        /// it" — the map keeps no resolved-id history to tell those apart,
        /// since every current caller treats them identically (nothing to
        /// mutate, nothing to send). A caller that later needs to log
        /// "duplicate terminal event" separately from "bogus id" would
        /// need a bounded resolved-id log added here; nothing today asks
        /// for that distinction, so it isn't built.
        case unknown
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// Current pending count — exposed so a cap-overflow test (or a caller)
    /// can confirm the untouched entries without re-deriving them from
    /// individual `resolve` probes.
    public var count: Int { entries.count }

    /// Non-mutating lookup. Exists for exactly one purpose: the B2 wrapper
    /// must compare a `permission-decision`'s `target` against the pending
    /// entry's submitted target *before* consuming it — a mismatched
    /// decision is discarded and the legitimate entry must stay pending
    /// (spec: "discarded, never applied"). `resolve` removes the entry
    /// unconditionally, so without this accessor a failed target check
    /// would have already destroyed the entry it was protecting. The
    /// peek-then-resolve pair is race-free under the caller contract above
    /// (one authoritative instance behind the caller's serialization).
    public func peek(id: String) -> Entry? {
        entries[id]
    }

    /// Admits a new request. `expiresAt` is whatever deadline the caller has
    /// already decided on (the spec's clamp/derivation is a wrapper's job,
    /// not this type's); this map does not compute it.
    public mutating func admit(id: String, target: String, tool: String, expiresAt: Date) -> AdmitOutcome {
        guard entries[id] == nil else {
            return .duplicate
        }
        guard expiresAt.timeIntervalSince1970.isFinite else {
            return .invalidDeadline
        }
        guard entries.count < BridgeTunables.pendingRequestCap else {
            return .overflow
        }
        let entry = Entry(id: id, target: target, tool: tool, expiresAt: expiresAt)
        entries[id] = entry
        return .admitted(entry)
    }

    /// Resolves `id` with `event`, or reports why nothing happened.
    ///
    /// **Why this takes `now`, not just the caller's claimed `event`:** the
    /// spec makes the deadline itself — not whichever code path happens to
    /// notice it — authoritative: "that local deadline is authoritative for
    /// UI teardown ... regardless of anything the helper does or fails to
    /// send." So an entry whose `expiresAt` has already passed by `now` is
    /// already terminal (expired) even if no one has explicitly called
    /// `resolve(..., event: .expired, ...)` for it yet, and even if the
    /// caller is trying to apply a *different* event. Concretely: once
    /// `now >= entry.expiresAt`, this call resolves as `.expired` regardless
    /// of the `event` argument — the deadline wins the race, not the label.
    /// This is deliberate for ALL events, not just decisions: a cancel or
    /// connection-loss landing after the deadline reports (and announces,
    /// per the accessibility contract) as the timeout it already was —
    /// expiry was the first terminal event, the late call merely observed
    /// it. It's also what makes "decision-then-expiry" and
    /// "expiry-then-decision" produce the same outcome once the clock has
    /// actually passed the deadline, independent of which call runs first.
    ///
    /// `now` must be a fresh reading taken at the point the caller
    /// serializes this state transition (the same injected-clock contract
    /// as `BridgeFrameReader.consume`): the deadline is only as
    /// authoritative as the clock the caller hands it, and a stale `now`
    /// makes the map mislabel the event.
    ///
    /// Boundary: `now == expiresAt` counts as expired (`>=`, not `>`) — same
    /// inclusive boundary as `sweepExpired`, so the two can't disagree about
    /// whether a request is still alive at the exact instant it's due.
    public mutating func resolve(id: String, event: TerminalEvent, now: Date) -> ResolveOutcome {
        guard let entry = entries[id] else {
            return .unknown
        }
        entries.removeValue(forKey: id)
        let effectiveEvent: TerminalEvent = now >= entry.expiresAt ? .expired : event
        return .resolved(entry, effectiveEvent)
    }

    /// Removes and returns every entry whose `expiresAt` has passed as of
    /// `now` (inclusive — see `resolve`'s boundary note), oldest deadline
    /// first so batch `permission-resolved` emission (task B2) is
    /// deterministic instead of dictionary-ordered. This is the bulk
    /// counterpart to calling `resolve(..., event: .expired, now:)` for
    /// each overdue id without the caller having to already know which ids
    /// are overdue.
    public mutating func sweepExpired(now: Date) -> [Entry] {
        let expired = entries.values
            .filter { $0.expiresAt <= now }
            .sorted { $0.expiresAt < $1.expiresAt }
        for entry in expired {
            entries.removeValue(forKey: entry.id)
        }
        return expired
    }

    /// Removes and returns every still-pending entry, unconditionally — the
    /// connection-lost bulk case (spec: "the connection dying (entry
    /// resolved as deny locally; nothing can be sent)"). No `now` and no
    /// expired-vs-pending partition on purpose: connection loss precludes
    /// sending anything either way, so the label changes no behavior; a
    /// caller that cares can read each returned `Entry.expiresAt`. A second
    /// call returns an empty array — every entry was already removed by the
    /// first, so "exactly once" falls out of the map being empty afterward
    /// rather than needing separate bookkeeping.
    public mutating func drainAll() -> [Entry] {
        defer { entries.removeAll() }
        return Array(entries.values)
    }
}
