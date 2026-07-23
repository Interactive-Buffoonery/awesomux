# Remove Ghostty wakeup coalescing — design

- **Status:** Approved
- **Date:** 2026-07-22

## Summary

awesoMux's occasional "Terminal Engine Unresponsive" alert (`GhosttyEventLoopWatchdog`, tracked in [#176](https://github.com/Interactive-Buffoonery/awesomux/issues/176)) traces to an open upstream bug in libxev's macOS kqueue backend ([mitchellh/libxev#122](https://github.com/mitchellh/libxev/issues/122)) that's sensitive to large I/O completion batches. awesoMux's `GhosttyWakeupCoalescer` (`Sources/awesoMux/Services/GhosttyRuntimeCallbacks.swift`) makes those batches bigger than they need to be: it's an app-wide latch that drops every `wakeup_cb` invocation arriving while a tick is already pending, deferring the drain across a `Task`-scheduling window and letting PTY output from multiple panes pile up before one `ghostty_app_tick` call drains all of it at once.

Stock Ghostty's own macOS reference integration (`vendor/ghostty/macos/Sources/Ghostty/Ghostty.App.swift:434-441`) does not coalesce — every wakeup schedules its own tick immediately. eD has run stock Ghostty.app extensively without hitting this; awesoMux hits it repeatedly. The coalescer's origin (`Interactive-Buffoonery/awesomux-private#94`, INT-377, "reduce terminal churn") bundled it as one unmeasured bullet in a broader perf pass — it was never independently profiled or shown to be load-bearing.

This change removes the coalescing latch so every wakeup schedules its own tick, matching stock's behavior, and adds a debug-level log line so tick cadence is observable if the notification recurs.

## Change 1: remove the coalescing latch

`GhosttyRuntime.wakeup` (`GhosttyRuntimeCallbacks.swift:15-29`) currently routes every wakeup through `GhosttyWakeupCoalescer.schedule`, which drops the call if a tick is already pending. Replace with an unconditional `Task { @MainActor in runtime.tick() }` per wakeup — no latch, no dropped wakeups, no cross-pane batching window. This is the direct equivalent of stock's per-wakeup `DispatchQueue.main.async { appTick() }`; `Task { @MainActor in }` is kept (rather than switching to raw GCD + `MainActor.assumeIsolated`) because `GhosttyRuntime` is `@MainActor`-isolated under Swift 6 strict concurrency, and `Task` is this codebase's existing idiom for that hop.

`GhosttyWakeupCoalescer` (the class, `GhosttyRuntimeCallbacks.swift:783-820`) is deleted entirely — no other caller exists.

No behavior change to what a tick *does* (`ghostty_app_tick` still drains everything accumulated since the previous tick, per the existing doc comment) — only how eagerly a tick gets scheduled after each wakeup.

## Change 2: tick-cadence log line

Add a single debug-level `Logger` call in `GhosttyRuntime.tick()` (`GhosttyRuntime.swift:1297`) that tracks time elapsed since the previous tick and logs it:

```swift
private var lastTickLoggedAt: Date?

func tick() {
    let now = Date()
    if let last = lastTickLoggedAt {
        logger.debug("tick fired \(now.timeIntervalSince(last), format: .fixed(precision: 3))s after previous tick")
    }
    lastTickLoggedAt = now
    // ...existing tick body unchanged
}
```

Uses the existing `Logger(subsystem: "com.interactivebuffoonery.awesomux", category: ...)` pattern already present elsewhere in this file (matches `GhosttyEventLoopWatchdog`'s own logging conventions). Local-only (OSLog), no network call, nothing collected across users. This gives a cheap signal — if ticks are still clustering into sub-millisecond bursts after removing the coalescer, that's visible in `log stream` without guessing.

No new types, no counters, no aggregation — just a timestamp diff on the existing hot path.

## Out of scope

- Per-surface latching (considered, rejected during brainstorming — `ghostty_app_tick` drains all surfaces in one call regardless of which pane's wakeup triggered it, so per-surface latches wouldn't shrink the batch handed to libxev).
- Bounded/max-delay coalescing (considered as a middle-ground option — rejected in favor of the simpler full removal, since the coalescer was never shown to be necessary).
- Any change to `GhosttyEventLoopWatchdog` itself, or the alert UI — those stay as the detection/mitigation layer regardless of this fix's effect on trigger frequency.
- Bumping the vendored `libxev` pin — no upstream fix exists yet (tracked in #176).

## Testing

- Existing Ghostty runtime/wakeup tests (if any reference `GhosttyWakeupCoalescer`) get updated to match the new direct-dispatch path.
- No new test framework needed — this is a scheduling-path simplification, not new branching logic. A quick manual smoke (open a few panes, confirm terminal output still renders correctly and promptly) is the practical verification; behavior is otherwise indistinguishable from before except tick timing.
- `./script/swift-test.sh` must still pass.
