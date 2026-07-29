import AwesoMuxCore
import Foundation

/// Pure trailing-edge throttle decision for high-frequency writes into the
/// `@Observable` session store.
///
/// Progress reports and terminal-title animations emit a NEW, DISTINCT value
/// on every tick, so `PaneLayoutReducer.updatePane`'s identical-value guard
/// provides no protection. Without this throttle each tick re-renders the
/// sidebar and pane chrome at PTY rate.
///
/// Leading + trailing hybrid: the first write after the window closes lands
/// immediately (good latency for a bar that just appeared), and any writes
/// that land WITHIN the window collapse into exactly one deferred write at
/// the window's close, always carrying the MOST RECENT value — so a fast
/// finish (…97%, 100%, remove) or settled terminal title can't be eaten by the
/// throttle. Side-effect free; tests live in
/// `TerminalEventDispatchPolicyTests`.
enum ObservableStoreWriteThrottle {
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

/// Guards a deferred terminal-event side effect against
/// `GhosttySurfaceNSView.update(session:pane:...)` re-pointing the SAME NSView
/// instance at a different pane between scheduling and execution.
///
/// Mirrors the snapshot-then-revalidate guard
/// `CommandBridgeEnactor.beginExitSupervision` already uses for its own
/// async exit-probe Task (INT-587 review).
/// Identifies the pane a throttled store write belongs to, so a recycled view
/// neither inherits the outgoing pane's throttle window nor cancels its
/// pending write.
struct PaneStoreWriteKey: Equatable {
    let sessionID: TerminalSession.ID
    let paneID: TerminalPane.ID
}

enum DeferredPaneEventDispatchGuard {
    static func shouldApply(
        capturedSessionID: TerminalSession.ID,
        capturedPaneID: TerminalPane.ID,
        currentSessionID: TerminalSession.ID,
        currentPaneID: TerminalPane.ID
    ) -> Bool {
        capturedSessionID == currentSessionID && capturedPaneID == currentPaneID
    }
}
