import Foundation

/// Time-boxed cache for the expensive `ghostty_surface_read_text` /
/// `GHOSTTY_POINT_SCREEN` read backing `GhosttySurfaceNSView`'s content
/// accessors.
///
/// libghostty's own doc comment on `ghostty_surface_read_text`
/// (`vendor/ghostty/src/apprt/embedded.zig:1626-1629`) warns it's expensive
/// and recommends callers cache + throttle; it also locks
/// `core_surface.renderer_state.mutex`, the same mutex the render thread
/// needs, and walks/allocates the *entire* scrollback for
/// `GHOSTTY_POINT_SCREEN`. VoiceOver's line/word navigation and "read all"
/// mode routinely fan out across `numberOfCharacters` → `visibleCharacterRange`
/// → `line(for:)` → `string(for:)` for a single navigation step, so without a
/// cache one arrow-key press could trigger 4+ full-scrollback mutex-locked
/// dumps on the main thread.
///
/// Mirrors Ghostty's own `CachedValue`
/// (`vendor/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift:2375-2411`),
/// including its exact 500ms duration
/// (`SurfaceView_AppKit.swift:235,244`), but checks expiry lazily on access
/// instead of scheduling an auto-eviction `Task` — nothing here needs to
/// proactively free the cached string before the next access, and lazy
/// expiry keeps this pure/synchronous and unit-testable without a live
/// `ContinuousClock`-driven task.
///
/// `@MainActor`-isolated by declaration. Not required by any *current* call
/// site — every touch site today (`GhosttySurfaceAccessibility`'s accessors,
/// `GhosttySurfaceNSView`'s lifecycle methods) already inherits MainActor
/// isolation from `NSResponder`'s `NS_SWIFT_UI_ACTOR` annotation, which
/// applies to every method of every subclass, not just overrides — so
/// reading/mutating this struct through its `self`-owned property was
/// already isolation-safe before this annotation existed. That upstream
/// annotation lives two levels up the class hierarchy from this file,
/// though, so nothing here made the isolation locally verifiable by reading
/// just this type; this annotation is a defense-in-depth lock against a
/// future call site that ISN'T on that inference path (e.g. this cache
/// getting pulled out from behind the class field into a free function or a
/// background-actor type). Mirrors the `unsafeSurface`/`surface` doc comment
/// in `GhosttySurfaceNSView.swift`, which states its own MainActor invariant
/// explicitly for the same reason. Cost: it forces
/// `GhosttySurfaceAccessibilityScreenContentsCacheTests` onto MainActor's
/// serial executor, losing swift-testing's default per-test parallelism.
@MainActor
struct GhosttySurfaceAccessibilityScreenContentsCache {
    private var value: String?
    private var expiresAt: ContinuousClock.Instant?

    static let duration: Duration = .milliseconds(500)

    /// Returns the cached value if still fresh as of `now`, otherwise calls
    /// `fetch()`, caches the result, and resets the expiry window. `now` is
    /// an injectable parameter (defaulting to the real clock) so cache-hit /
    /// cache-miss behavior is testable without sleeping in tests.
    mutating func get(now: ContinuousClock.Instant = .now, fetch: () -> String) -> String {
        if let value, let expiresAt, now < expiresAt {
            return value
        }

        let result = fetch()
        value = result
        expiresAt = now + Self.duration
        return result
    }

    /// Drops the cached value so the next `get()` re-fetches regardless of
    /// the expiry window. Called on `GHOSTTY_ACTION_SELECTION_CHANGED` and
    /// from the passive visible-state sampler's `.valueChanged` announcement
    /// (`scheduleAccessibilityValueChangeAnnouncement()`) — the two push
    /// signals awesoMux has for "something about this surface's content just
    /// changed." Outside of those, the 500ms expiry window alone is the
    /// freshness guarantee, same as Ghostty itself relies on.
    mutating func invalidate() {
        value = nil
        expiresAt = nil
    }
}
