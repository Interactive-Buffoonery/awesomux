import AwesoMuxCore
import Foundation

/// The app's local record of the remote socket path and generation it minted
/// for each attach key, including stale remote socket cleanup:
///
/// - It is the **sole deletion authority**. Every `rm -f` the attach/teardown
///   paths run sources its path from here, by exact value. Nothing globs the
///   shared `/tmp/awesomux-bridge-*` prefix — an age- or wildcard-based sweep
///   would unlink a healthy sibling pane's live reverse-forward socket.
/// - It is where `previousGeneration` for the next `BridgeChannel.mint` comes
///   from, so `gen` increments monotonically within one app run.
///
/// The ledger survives only within a run: app-crash orphans (ledger lost) are
/// the spec's one accepted leak — inert files a doctor repair action may offer
/// to clean interactively, never automatically.
///
/// `actor`-isolated because attach preflights for *different* panes run
/// concurrently off-main and all key into this one shared record; per-pane
/// serialization guards a single session's entries, not cross-session access.
actor BridgeSocketLedger {
    struct Entry: Sendable, Equatable {
        let generation: Int
        let remoteSocketPath: String
        /// When this generation was published. The doctor's orphan-cleanup
        /// story needs an age; the value is injected (not read from a live
        /// clock here) so callers stay deterministic under test.
        let mintedAt: Date
    }

    private var entries: [TerminalSessionID: Entry] = [:]

    /// The generation to hand `BridgeChannel.mint` as `previousGeneration`.
    /// Zero when this session has no live generation — the fresh-epoch case
    /// (first attach, or the first attach after an app restart lost the
    /// counter), which mints `gen: 1` exactly as the spec's epoch rules expect.
    func previousGeneration(for session: TerminalSessionID) -> Int {
        entries[session]?.generation ?? 0
    }

    /// Records the newly-published generation and returns the entry it
    /// replaced, so the caller can break exactly that prior generation's
    /// remote socket by its exact path. Called at the readiness commit (attach
    /// step 4), never before — an unpublished mint must not roll the ledger
    /// forward, or a failed publish would orphan the true live generation's
    /// deletion authority.
    @discardableResult
    func commit(
        session: TerminalSessionID,
        generation: Int,
        remoteSocketPath: String,
        mintedAt: Date
    ) -> Entry? {
        let previous = entries[session]
        entries[session] = Entry(
            generation: generation,
            remoteSocketPath: remoteSocketPath,
            mintedAt: mintedAt
        )
        return previous
    }

    /// The exact remote socket path last minted for `session`, for the
    /// pane-close teardown path (a different caller than the preflight, which
    /// already gets the prior path back from `commit`). Removal by this exact
    /// value only — callers never derive a glob from it.
    func remoteSocketPath(for session: TerminalSessionID) -> String? {
        entries[session]?.remoteSocketPath
    }

    /// Drops a session's entry once its pane has fully closed and its socket
    /// has been removed by exact path. Idempotent.
    func forget(_ session: TerminalSessionID) {
        entries.removeValue(forKey: session)
    }

    /// Atomic compare-and-forget: drops the entry only if it still names
    /// `remoteSocketPath`. A teardown that captured a generation's own socket
    /// path uses this so a successor re-mint's entry — committed under the same
    /// session key while the teardown was suspended on its ssh awaits — is never
    /// mistakenly forgotten (which would reset the successor's
    /// `previousGeneration` to 0). The check and the removal must share one
    /// actor hop; a caller doing `remoteSocketPath(for:)` then `forget(_:)`
    /// reopens exactly the race this closes. Idempotent.
    func forget(_ session: TerminalSessionID, ifMatches remoteSocketPath: String) {
        guard entries[session]?.remoteSocketPath == remoteSocketPath else { return }
        entries.removeValue(forKey: session)
    }
}
