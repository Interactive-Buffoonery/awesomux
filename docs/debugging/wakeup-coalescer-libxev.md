# Wakeup coalescing and the libxev kqueue stall (issue #176)

Analysis for **open issue #176** — "terminal engine unresponsive alert triggered
by libxev kqueue bug under bursty wakeups". This records an approach that was
designed but **never executed**, so the reasoning is not recoverable from the
code.

**Status: unresolved.** `GhosttyWakeupCoalescer` is still live at
`GhosttyRuntimeCallbacks.swift`, and `wakeup(_:)` still routes through
`.schedule`. What shipped on the branch that carried this analysis was #181
(*"anchor wedge staleness to un-serviced wakeups, not idle time"*) — a
**different** fix. The coalescer was not removed; it was **extended** with
`pendingWakeupAge`, and `GhosttyEventLoopWatchdog` now depends on it, naming "a
stuck coalescer latch" as one of the two conditions it exists to detect.

That partially inverts the premise below. Read it as a record of an unexecuted
option, not a plan to pick up unchanged.

## Stock Ghostty does not coalesce

Upstream's macOS reference integration
(`vendor/ghostty/macos/Sources/Ghostty/Ghostty.App.swift`) schedules a tick per
wakeup — `DispatchQueue.main.async { appTick() }`. Stock Ghostty.app has been run
extensively without hitting #176; awesoMux hits it repeatedly.

## The coalescer was never measured

Its origin bundled it as one unmeasured bullet in a broader "reduce terminal
churn" performance pass. It was never independently profiled or shown to be
load-bearing.

## The batch-size story is a hypothesis, not a mechanism

An architecture review falsified the framing. "Coalescing → bigger completion
batches → more likely to trip libxev#122" is plausible and evidence-consistent
but **unconfirmed**. The upstream bug describes a leftover-unflushed-changes
condition tied to `.no_wait` semantics, which could equally be sensitive to *call
frequency* as to *batch size*. No experiment yet distinguishes the two.

**Instrument (tick-cadence logging) before removing anything.** The original plan
was reordered specifically so a baseline would exist to compare against.

## Two alternatives already considered and rejected

- **Per-surface latching.** `ghostty_app_tick` drains all surfaces in one call
  regardless of which pane's wakeup triggered it, so per-surface latches would
  not shrink the batch handed to libxev.
- **Bounded / max-delay coalescing.** Rejected in favour of full removal, since
  the coalescer was never shown to be necessary.

## Constraints if the latch is ever deleted

1. The contract "one `ghostty_app_tick` call drains every wakeup since the last
   tick" lives in `GhosttyWakeupCoalescer`'s doc comment, and
   `GHOSTTY_ACTION_PROGRESS_REPORT`'s synchronous-dispatch safety argument in
   `GhosttyRuntimeCallbacks.swift` **cites it**. Relocate that explanation or the
   citation dangles.
2. `GhosttyEventLoopWatchdog` now reads `pendingWakeupAge` off the coalescer.
   Removing the latch means rebuilding the watchdog's staleness signal — a
   dependency that postdates the original analysis and which it does not account
   for.
