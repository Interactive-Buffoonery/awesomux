import AwesoMuxCore

enum SurfaceResizeUpdateDecision: Equatable {
    case applyImmediately
    case deferUntilSettled
    case skip
}

enum SurfaceResizeUpdatePolicy {
    /// Decides how a surface backing-state change reaches libghostty.
    ///
    /// Same-scale size changes are coalesced while a resize is in progress, so the
    /// terminal reflows once at settle instead of on every frame — that per-frame
    /// reflow (and the blank flash it causes) is the artifact this guards against.
    /// There are three coalescing sources:
    ///   1. a window drag, and
    ///   2. a native `NSSplitView` sidebar-divider drag (INT-535) — both raise
    ///      AppKit `isInLiveResize`, which the caller passes through; and
    ///   3. the programmatic eased sidebar-divider *settle* animation (#81), which
    ///      moves the divider via `animator().setPosition` and so never raises
    ///      `isInLiveResize` — the caller signals it with `isSettlingDividerAnimation`.
    /// Each reflows once when it ends. Every other path — plain programmatic layout
    /// and the cold-launch settle that follows surface creation — applies immediately
    /// so the child PTY's winsize is never stale. That immediacy is what protects
    /// fastfetch cold-launch sizing (INT-289): a freshly created surface has a `nil`
    /// `lastApplied` and always applies immediately, and the settle correction that
    /// follows it is neither a live resize nor a divider-settle animation, so it
    /// applies immediately too.
    static func decision(
        lastApplied: SurfaceBackingState?,
        next: SurfaceBackingState,
        isInLiveResize: Bool,
        isSettlingDividerAnimation: Bool
    ) -> SurfaceResizeUpdateDecision {
        guard let lastApplied else {
            return .applyImmediately
        }

        guard lastApplied != next else {
            return .skip
        }

        if lastApplied.geometry.scale != next.geometry.scale
            || lastApplied.isVisible != next.isVisible
        {
            return .applyImmediately
        }

        // Same-scale size change: coalesce during any active resize — a window or
        // divider drag (`isInLiveResize`) or the eased divider settle.
        return isInLiveResize || isSettlingDividerAnimation
            ? .deferUntilSettled : .applyImmediately
    }
}
