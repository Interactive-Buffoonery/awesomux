import Foundation

/// Id-keyed, capped pending permission requests with first-terminal-event-wins
/// resolution. The owning wrapper keeps one authoritative instance.
/// Copies resolve independently; serialize transitions against the original,
/// never a snapshot. `Sendable` does not make copies shared state.
///
/// Target binding, `permission-resolved` emission, FIFO presentation, timeout
/// clamping, and grants belong to the wrapper. `peek(id:)` lets it validate a
/// decision's target before consuming the request.
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
        /// confused-deputy `target` check compares against — the user would
        /// have been shown one target while the map quietly held another.
        /// Checked before the cap so a duplicate at-cap reports as
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
        /// No pending entry: never-admitted and already-resolved IDs are indistinguishable.
        case unknown
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public var count: Int { entries.count }

    /// Lets the wrapper validate a decision target before consuming the entry.
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

    /// Resolves `id` with `event`. A fresh `now >= expiresAt` wins as `.expired`
    /// for every event, including cancellation and connection loss; this matches
    /// `sweepExpired` at the exact deadline. Read `now` where the caller
    /// serializes this transition.
    public mutating func resolve(id: String, event: TerminalEvent, now: Date) -> ResolveOutcome {
        guard let entry = entries[id] else {
            return .unknown
        }
        entries.removeValue(forKey: id)
        let effectiveEvent: TerminalEvent = now >= entry.expiresAt ? .expired : event
        return .resolved(entry, effectiveEvent)
    }

    /// Removes expired entries in deadline order for deterministic emission.
    public mutating func sweepExpired(now: Date) -> [Entry] {
        let expired = entries.values
            .filter { $0.expiresAt <= now }
            .sorted { $0.expiresAt < $1.expiresAt }
        for entry in expired {
            entries.removeValue(forKey: entry.id)
        }
        return expired
    }

    /// Removes every pending entry for connection loss.
    public mutating func drainAll() -> [Entry] {
        defer { entries.removeAll() }
        return Array(entries.values)
    }
}
