import CoreGraphics
import Foundation

enum ColdStartSurfaceCreationDecision: Equatable {
    case create
    case wait
}

/// Tracking state for the cold-start spawn settle. Value type so the decision
/// stays pure and unit-testable; the surface view owns one instance and threads
/// it through `decision(...)` on every layout/poll tick. Time is a monotonic
/// `ContinuousClock.Instant` so a boot-time wall-clock correction (NTP sync at
/// login lands inside this exact window) cannot skew the settle.
///
/// `anchorAt != nil` also marks "this pane has entered the cold-start wait" — the
/// surface view uses it to keep settling a still-ramping split sibling even after
/// another pane has spawned and ended the global cold-start phase.
struct ColdStartSurfaceCreationState: Equatable {
    var anchorAt: ContinuousClock.Instant?
    var lastObservedWidth: CGFloat?
    var widthStableSince: ContinuousClock.Instant?

    init() {}
}

/// Decides WHEN a cold-launch libghostty surface may be created.
///
/// At cold boot the terminal-detail pane is laid out at a placeholder width
/// (~324 pt observed) for a few hundred ms before the native `NSSplitView`
/// (INT-535) and window-frame restore settle it to the real width. The shell —
/// and any one-shot, `TIOCGWINSZ`-sensitive `.zshrc` tool like fastfetch —
/// spawns when the surface is created, so spawning against that placeholder
/// bakes a ~32-column layout into scrollback that never reflows (re-rendering
/// prompts like Starship/p10k recover; fastfetch can't). The earlier fixed
/// 120 ms fallback (INT-289) expired before the ~316 ms settle, re-exposing the
/// squish.
///
/// This waits for a *settled* width instead of a fixed timeout. A width counts
/// as settled once it is at/above `plausibleWidthFloor` AND has held unchanged
/// for `widthStabilityInterval` — the placeholder→real ramp resolves to the
/// final width before spawn.
///
/// A width below the floor is left for `safetyCapInterval` and then spawned at
/// anyway. This is deliberately NOT optimized: a below-floor width can't be told
/// apart from a placeholder about to jump (a 1 pt jitter from rounding or a
/// scrollbar toggle would otherwise masquerade as a settled real width and spawn
/// squished). Waiting for the cap costs a genuinely-narrow pane — a small window,
/// or a split sub-pane under ~480 pt — up to a second before its shell appears,
/// but by then the layout has settled and it spawns at its *real* width, where
/// PTY == viewport and fastfetch renders fine. Correct-but-slow beats fast-but-
/// occasionally-squished for that rare case.
///
/// The delay is deliberately NOT gated on Reduce Motion: it is layout-settle
/// timing, not animation. Honoring Reduce Motion here would hand motion-
/// sensitive users a permanently squished terminal.
enum ColdStartSurfaceCreationPolicy {
    /// At/above this width a pane is plausibly its real size. It mirrors the
    /// terminal pane's enforced minimum, `ContentView.terminalMinimumWidth` (fed
    /// to `SidebarSplitController`); a settled single detail pane never lands
    /// below it, so any below-floor width is either a transitional placeholder or
    /// a genuinely narrow split sub-pane, both resolved by the safety cap rather
    /// than guessed at. Kept as a literal to keep this policy free of a backwards
    /// dependency on the view layer; `ColdStartSurfaceCreationPolicyTests` asserts
    /// the two stay equal so a drift fails the build instead of silently allowing
    /// creation at a width the split controller would clamp below.
    static let plausibleWidthFloor: CGFloat = 480

    /// How long a width must hold unchanged to count as settled. Long enough to
    /// bridge the gaps between successive layout proposals during the settle
    /// ramp, short enough to be imperceptible at launch.
    static let widthStabilityInterval: Duration = .milliseconds(100)

    /// Absolute ceiling on the cold-start wait, measured from the first decision
    /// while the window is visible (a window occluded at boot resets the settle,
    /// since a width that can't be laid out can't be trusted). Spawn anyway once
    /// it elapses so a genuinely tiny or pathologically slow-settling window is
    /// never stranded without a shell.
    static let safetyCapInterval: Duration = .seconds(1)

    /// Whether a pane may skip the settle and spawn its surface immediately.
    ///
    /// True only for a genuinely warm pane: the global cold-start phase has
    /// ended (some surface already exists), this pane never entered the settle
    /// wait, AND its proposed width is at/above the floor — i.e. it was laid out
    /// into an already-settled window, so its first proposal is the real width.
    ///
    /// The width check is the INT-548 fix. The global cold-start phase is a
    /// runtime-wide flag — it flips the instant *any* pane spawns — so on a
    /// restored split a late-mounting sibling can find the phase already over
    /// while its own width is still the ramping ~324pt placeholder. Trusting the
    /// phase alone spawned that sibling immediately at the placeholder, baking a
    /// ~32-column PTY that one-shot `.zshrc` tools (fastfetch) never reflow. A
    /// below-floor width is never trustworthy as "settled" here, so it falls
    /// through to `decision(...)` where the floor + safety cap govern the spawn.
    /// The cost is that a genuinely narrow warm split (<floor) waits for the cap
    /// rather than spawning instantly — the same correct-but-slow tradeoff the
    /// cold-start path already accepts for narrow panes.
    static func canSpawnImmediately(
        isColdStartPhase: Bool,
        paneEnteredColdStartWait: Bool,
        width: CGFloat
    ) -> Bool {
        !isColdStartPhase
            && !paneEnteredColdStartWait
            && width >= plausibleWidthFloor
    }

    static func decision(
        state: inout ColdStartSurfaceCreationState,
        width: CGFloat,
        now: ContinuousClock.Instant
    ) -> ColdStartSurfaceCreationDecision {
        if state.anchorAt == nil {
            state.anchorAt = now
        }
        let anchor = state.anchorAt ?? now

        if state.lastObservedWidth != width {
            state.lastObservedWidth = width
            state.widthStableSince = now
        }
        let stableSince = state.widthStableSince ?? now
        let isStable = (now - stableSince) >= widthStabilityInterval
        if isStable, width >= plausibleWidthFloor {
            return .create
        }

        if (now - anchor) >= safetyCapInterval {
            return .create
        }

        return .wait
    }
}
