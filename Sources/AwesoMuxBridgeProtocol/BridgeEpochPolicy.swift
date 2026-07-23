import Foundation

/// The pure `gen`/token comparison rules, factored out so both sides of the bridge —
/// the app tracking what it last published, and (per the INT-698
/// contributor ruling) any helper-side code that wants to reason about a
/// candidate against a known-good baseline — consult one implementation
/// instead of two hand-mirrored copies.
///
/// **Rollback resistance comes from the token, not the counter.** `gen` is
/// only a same-epoch ordering hint — the app restarts without persisting
/// pane runtime state, so a legitimate post-restart publish can read
/// `gen: 1` again, and a policy that blindly rejected "lower gen" forever
/// would brick the bridge after every restart. What actually stops a
/// replayed stale file from doing damage is that its `token` cannot
/// complete a handshake (the app only ever accepts its current mint): the
/// worst a replayed old file costs is one cleanly failed connection
/// attempt, never a silent rollback to stale credentials. The counter's own
/// job is narrower — it only stops a same-epoch concurrent-write loser from
/// silently winning without a re-handshake.
public enum BridgeEpochPolicy {
    public enum Decision: Sendable, Equatable {
        /// Candidate matches the current baseline (or is a stale-but-
        /// harmless replay within the same epoch); keep using what's
        /// already active, no reconnection needed. The caller's stored
        /// baseline stays exactly as it is — the app mints a fresh token
        /// with every publish, so a same-token candidate can only be the
        /// baseline's own publish read back, never a newer one.
        case useExisting
        /// Candidate is normal forward progress (or the first-ever
        /// baseline); adopt it.
        case adopt
        /// Candidate carries a different token at an equal-or-lower `gen` —
        /// possibly a genuine new epoch (e.g. post-restart `gen: 1`),
        /// possibly a stale replay. Neither can be told apart without
        /// attempting a connection; see `resolveEpochCandidate`.
        case epochCandidate
        /// An epoch candidate whose handshake failed — a stale replay,
        /// confirmed. Never returned directly by `decide`.
        case ignore
    }

    /// Compares a candidate `(gen, token)` read from the state file against
    /// the last `(gen, token)` known to have completed a handshake.
    ///
    /// **Caller contract — baseline lifetime.** `current` must be one
    /// long-lived in-memory value per process, threaded across every read.
    /// The INT-698 "no durable helper-side epoch cache" ruling means no
    /// *disk* persistence — it does NOT mean reset-to-nil per read. A caller
    /// that passes `nil` on every read routes everything through the
    /// bootstrap `.adopt` branch and the gen comparison never fires; the
    /// handshake token check still stops a credential rollback, but the
    /// same-epoch concurrent-write detection this counter exists for is
    /// silently defeated.
    ///
    /// - Parameter current: `nil` when there is no prior baseline at all —
    ///   the very first read this process (or this pure-policy caller) has
    ///   ever made. The spec's rules are all written in terms of comparing
    ///   against an existing baseline; with none to compare against there is
    ///   nothing to protect, so the first candidate simply becomes the
    ///   baseline (`.adopt`).
    public static func decide(
        current: (gen: Int, token: String)?,
        candidate: (gen: Int, token: String)
    ) -> Decision {
        guard let current else {
            return .adopt
        }

        if candidate.token == current.token {
            // "Same token → same generation; use it." Checked before the
            // gen comparison so a same-token candidate is never routed
            // through the higher-gen branch below — token identity alone is
            // sufficient, regardless of how `gen` happens to compare.
            return .useExisting
        }

        if candidate.gen > current.gen {
            return .adopt
        }

        // Equal-or-lower gen, different token: could be a genuine new epoch
        // (post-restart gen reset) or a stale replay. Only a handshake
        // attempt can tell them apart.
        return .epochCandidate
    }

    /// Resolves an `.epochCandidate` after the caller has actually attempted
    /// the connection. `decide()` cannot make this call itself — it has no
    /// way to attempt a handshake — so the caller drives this explicit
    /// two-step: try the candidate, then report back whether the handshake
    /// completed.
    ///
    /// A completed handshake proves the candidate's token is live and
    /// commits it as the new epoch baseline (`.adopt`); a failed handshake
    /// proves the file was a stale replay, so the caller keeps its old
    /// baseline untouched (`.ignore`).
    public static func resolveEpochCandidate(handshakeSucceeded: Bool) -> Decision {
        handshakeSucceeded ? .adopt : .ignore
    }
}
