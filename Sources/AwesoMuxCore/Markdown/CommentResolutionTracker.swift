/// Detects the "all comments resolved" moment for a watched document: the point
/// where the comment count drops from one or more to zero (INT-683).
///
/// The document pane rebuilds its `RenderedDocument` on every reload (initial
/// open, filesystem watch, self-write). Feeding each reload's comment count
/// through `observe(commentCount:)` reports exactly the `> 0 -> 0` transition
/// and nothing else:
///
/// - The first observation (initial load) never fires — a document that opens
///   with no comments is not a "just resolved" event.
/// - Only a drop *to* zero fires; going 3 -> 1 or 0 -> 2 does not.
/// - The drop is a *candidate* that must settle before it shows: a non-atomic
///   agent rewrite can momentarily read as a comment-free file, so the caller
///   waits a settle interval between `observe` returning `true` and calling
///   `confirmResolve()`. A nonzero count observed inside that window (the
///   2 -> 0 -> 2 bounce) cancels the candidate and nothing fires.
/// - The value is pure and `Sendable`, so the transition and settle rules are
///   unit-tested without a live view, filesystem, or clock.
public struct CommentResolutionTracker: Equatable, Sendable {
    /// The last observed count, or `nil` before the first observation. `nil` is
    /// what makes the initial load a no-op regardless of its count.
    public private(set) var lastCount: Int?
    /// True while a `> 0 -> 0` drop is waiting out the caller's settle interval.
    public private(set) var isSettling = false

    public init() {
        lastCount = nil
    }

    /// Record a reload's comment count. Returns `true` exactly when this
    /// observation starts a settle window for a `> 0 -> 0` drop — the caller
    /// should call `confirmResolve()` after its settle interval elapses. Any
    /// nonzero count cancels a pending window.
    public mutating func observe(commentCount: Int) -> Bool {
        defer { lastCount = commentCount }
        guard let previous = lastCount else { return false }
        if commentCount > 0 {
            isSettling = false
            return false
        }
        if previous > 0, !isSettling {
            isSettling = true
            return true
        }
        return false
    }

    /// The settle interval elapsed. Returns `true` exactly when the drop is
    /// still standing (no comments reappeared meanwhile) — the moment to show
    /// the resolved notice.
    public mutating func confirmResolve() -> Bool {
        defer { isSettling = false }
        return isSettling
    }
}
