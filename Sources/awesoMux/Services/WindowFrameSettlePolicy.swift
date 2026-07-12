import CoreGraphics
import Foundation

enum WindowFrameSettleDecision: Equatable {
    case proceed
    case wait
}

/// Per-view tracking state for the window-frame settle. Value type so the
/// decision stays pure and unit-testable; each surface view owns one and threads
/// it through `decision(...)` on every layout/poll tick. Monotonic
/// `ContinuousClock.Instant` so a boot-time NTP correction can't skew the settle.
///
/// Per-view (not process-global) on purpose: a fresh view on window-reopen or a
/// second window starts with clean state, so the settle can't be "used up" by an
/// earlier window.
struct WindowFrameSettleState: Equatable {
    var lastFrame: CGRect?
    var firstObservedAt: ContinuousClock.Instant?
    var lastChangeAt: ContinuousClock.Instant?

    init() {}
}

/// Decides WHEN a cold-launch libghostty surface may be created, gated on the
/// *window frame* having stopped moving.
///
/// At cold launch SwiftUI/AppKit can still step the window through intermediate
/// frames while scene placement, screen constraints, and split layout settle.
/// The shell — and any one-shot, `TIOCGWINSZ`-sensitive `.zshrc` tool like
/// fastfetch — spawns when the surface is created, so spawning mid-ramp bakes a
/// too-narrow column count into scrollback that never reflows (INT-548). The
/// earlier pane-width settle (`ColdStartSurfaceCreationPolicy`) couldn't bridge
/// this: a transitional width can sit above the floor and hold longer than its
/// short stability window, reading as "settled" while the window is still moving.
///
/// This waits for the *window frame itself* to go quiet. The frame counts as
/// settled once it has held unchanged for `settleInterval`; every frame change
/// restarts the clock, so the spawn lands after the window reaches its final
/// frame. A `safetyCapInterval` ceiling guarantees a
/// window whose frame never quiesces (a tiling WM continuously nudging it) still
/// spawns rather than stranding the pane without a shell.
///
/// Frame-owner-agnostic by design: it doesn't care whether SwiftUI, AppKit, or
/// anything else moved the window — only that the motion stopped. That keeps the
/// fix working regardless of who restores the frame, and avoids awesoMux having
/// to own (and regress) multi-display frame restoration.
///
/// Not gated on Reduce Motion: this is layout-settle timing, not animation.
enum WindowFrameSettlePolicy {
    /// How long the window frame must hold unchanged to count as settled. Long
    /// enough to bridge observed early launch frame changes, with margin; short
    /// enough to stay imperceptible at launch.
    static let settleInterval: Duration = .milliseconds(350)

    /// Absolute ceiling on the wait, measured from the first observation. Spawn
    /// anyway once it elapses so a frame that never quiesces can't strand a pane.
    static let safetyCapInterval: Duration = .seconds(2)

    static func decision(
        state: inout WindowFrameSettleState,
        windowFrame: CGRect,
        now: ContinuousClock.Instant
    ) -> WindowFrameSettleDecision {
        if state.firstObservedAt == nil {
            state.firstObservedAt = now
            state.lastChangeAt = now
            state.lastFrame = windowFrame
        }
        if state.lastFrame != windowFrame {
            state.lastFrame = windowFrame
            state.lastChangeAt = now
        }

        let firstObservedAt = state.firstObservedAt ?? now
        if (now - firstObservedAt) >= safetyCapInterval {
            return .proceed
        }

        let lastChangeAt = state.lastChangeAt ?? now
        if (now - lastChangeAt) >= settleInterval {
            return .proceed
        }

        return .wait
    }
}
