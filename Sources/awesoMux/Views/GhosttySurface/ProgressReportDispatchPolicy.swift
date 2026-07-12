import AwesoMuxCore
import Foundation

/// Pure trailing-edge throttle decision for `progressReport` writes into the
/// `@Observable` session store.
///
/// A fast-ticking build tool emits a NEW, DISTINCT percentage on every OSC
/// 9;4 tick (0%, 1%, 2%, …), so `PaneLayoutReducer.updatePane`'s no-op guard
/// — which only dedupes IDENTICAL reports — provides zero protection against
/// the write rate. Without this throttle each tick re-renders the sidebar +
/// pane chrome at PTY rate (INT-587 review; same shape as the INT-523
/// path-bar debounce in `TerminalPathBarResolvePolicy`).
///
/// Leading + trailing hybrid: the first write after the window closes lands
/// immediately (good latency for a bar that just appeared), and any writes
/// that land WITHIN the window collapse into exactly one deferred write at
/// the window's close, always carrying the MOST RECENT value — so a fast
/// finish (…97%, 100%, remove) can't have its terminal state eaten by the
/// throttle. Side-effect free; tests live in
/// `ProgressReportDispatchPolicyTests`.
enum ProgressReportWriteThrottle {
    enum Decision: Equatable {
        /// Commit the store write now and reset the throttle window.
        case writeNow
        /// Still inside the window — defer the write by this many seconds,
        /// carrying whatever the caller's latest value is at that point.
        case deferBy(TimeInterval)
    }

    static func decide(
        now: TimeInterval,
        lastWriteAt: TimeInterval?,
        minInterval: TimeInterval
    ) -> Decision {
        guard let lastWriteAt else {
            return .writeNow
        }

        let elapsed = now - lastWriteAt
        guard elapsed < minInterval else {
            return .writeNow
        }

        return .deferBy(minInterval - elapsed)
    }
}

/// Guards a deferred progress-report side effect (the throttle's trailing
/// write, or the 15s auto-expiry) against `GhosttySurfaceNSView.update
/// (session:pane:...)` re-pointing the SAME NSView instance at a different
/// pane between when the effect was scheduled and when it fires — a real
/// view-recycle path. Without this, a report scheduled for pane A can land
/// on pane B if a recycle happens in the gap.
///
/// Mirrors the snapshot-then-revalidate guard
/// `CommandBridgeEnactor.beginExitSupervision` already uses for its own
/// async exit-probe Task (INT-587 review).
enum ProgressReportDispatchGuard {
    static func shouldApply(
        capturedSessionID: TerminalSession.ID,
        capturedPaneID: TerminalPane.ID,
        currentSessionID: TerminalSession.ID,
        currentPaneID: TerminalPane.ID
    ) -> Bool {
        capturedSessionID == currentSessionID && capturedPaneID == currentPaneID
    }
}
