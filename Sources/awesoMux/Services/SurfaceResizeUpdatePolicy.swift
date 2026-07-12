import AwesoMuxCore

enum SurfaceResizeUpdateDecision: Equatable {
    case applyImmediately
    case deferUntilSettled
    case skip
}

enum SurfaceResizeUpdatePolicy {
    /// Decides how a surface backing-state change reaches libghostty.
    ///
    /// Same-scale size changes are coalesced while `isInLiveResize` is true, so
    /// the terminal reflows once at settle instead of on every frame — that
    /// per-frame reflow is the resize artifact this guards against. The caller
    /// raises `isInLiveResize` for a real AppKit live-resize: a window drag or a
    /// native `NSSplitView` sidebar-divider drag (INT-535, both surface as
    /// `inLiveResize`) — each reflows once when it settles. Every other path —
    /// programmatic layout and the cold-launch settle that follows surface
    /// creation — applies immediately so the child PTY's winsize is never stale.
    /// That immediacy is
    /// what protects fastfetch cold-launch sizing (INT-289): a freshly created
    /// surface has a `nil` `lastApplied` and always applies immediately, and the
    /// settle correction that follows it isn't a live resize, so it applies
    /// immediately too.
    static func decision(
        lastApplied: SurfaceBackingState?,
        next: SurfaceBackingState,
        isInLiveResize: Bool
    ) -> SurfaceResizeUpdateDecision {
        guard let lastApplied else {
            return .applyImmediately
        }

        guard lastApplied != next else {
            return .skip
        }

        if lastApplied.geometry.scale != next.geometry.scale
            || lastApplied.isVisible != next.isVisible {
            return .applyImmediately
        }

        // Same-scale size change: coalesce only during an active window drag.
        return isInLiveResize ? .deferUntilSettled : .applyImmediately
    }
}
