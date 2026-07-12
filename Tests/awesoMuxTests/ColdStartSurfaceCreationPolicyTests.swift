import CoreGraphics
import Foundation
import Testing
@testable import awesoMux

@Suite("Cold start surface creation policy")
struct ColdStartSurfaceCreationPolicyTests {
    private let floor = ColdStartSurfaceCreationPolicy.plausibleWidthFloor
    private let stability = ColdStartSurfaceCreationPolicy.widthStabilityInterval
    private let cap = ColdStartSurfaceCreationPolicy.safetyCapInterval
    private let start = ContinuousClock.now

    @Test("the plausibility floor stays equal to the terminal pane's enforced minimum")
    @MainActor
    func floorMatchesTerminalMinimumWidth() {
        // The floor is a literal to keep the policy free of a view-layer
        // dependency; this guards against silent drift from the canonical source.
        #expect(ColdStartSurfaceCreationPolicy.plausibleWidthFloor == ContentView.terminalMinimumWidth)
    }

    @Test("a width exactly at the floor settles (the boundary is inclusive)")
    func widthExactlyAtFloorSettles() {
        var state = ColdStartSurfaceCreationState()

        let first = ColdStartSurfaceCreationPolicy.decision(
            state: &state, width: floor, now: start
        )
        let afterSettled = ColdStartSurfaceCreationPolicy.decision(
            state: &state, width: floor, now: start + stability
        )

        #expect(first == .wait)
        #expect(afterSettled == .create)
    }

    @Test("a plausible width must hold for the stability interval before spawning")
    func plausibleWidthWaitsForStability() {
        var state = ColdStartSurfaceCreationState()

        let first = ColdStartSurfaceCreationPolicy.decision(
            state: &state, width: floor + 200, now: start
        )
        let beforeSettled = ColdStartSurfaceCreationPolicy.decision(
            state: &state, width: floor + 200, now: start + stability / 2
        )
        let afterSettled = ColdStartSurfaceCreationPolicy.decision(
            state: &state, width: floor + 200, now: start + stability
        )

        #expect(first == .wait)
        #expect(beforeSettled == .wait)
        #expect(afterSettled == .create)
    }

    @Test("an unchanged below-floor placeholder never settles on its own, even when stable")
    func placeholderBelowFloorNeverSettles() {
        // The regression: the ~324pt cold-boot placeholder sits unchanged for
        // longer than the stability window, so a stability-only check would
        // spawn against it. An unchanged below-floor width must not settle.
        var state = ColdStartSurfaceCreationState()

        let first = ColdStartSurfaceCreationPolicy.decision(
            state: &state, width: floor - 156, now: start
        )
        let muchLater = ColdStartSurfaceCreationPolicy.decision(
            state: &state, width: floor - 156, now: start + stability * 3
        )

        #expect(first == .wait)
        #expect(muchLater == .wait)
    }

    @Test("a below-floor width that changed but stayed below the floor still waits for the cap")
    func belowFloorChangedButStillBelowWaitsForCap() {
        // A 1pt jitter (rounding / scrollbar toggle) from the placeholder must
        // NOT be mistaken for a settled real width — otherwise a 324 -> 325 -> 1134
        // ramp would spawn squished at 325. Any below-floor width waits for the cap;
        // by then a genuinely narrow pane has settled at its real (small) width.
        var state = ColdStartSurfaceCreationState()

        let placeholder = ColdStartSurfaceCreationPolicy.decision(
            state: &state, width: 324, now: start
        )
        let jittered = ColdStartSurfaceCreationPolicy.decision(
            state: &state, width: 325, now: start + .milliseconds(60)
        )
        let stillBelowAfterStability = ColdStartSurfaceCreationPolicy.decision(
            state: &state, width: 325, now: start + .milliseconds(60) + stability
        )

        #expect(placeholder == .wait)
        #expect(jittered == .wait)
        #expect(stillBelowAfterStability == .wait)
        #expect(floor > 325) // guard: this case stays genuinely below the floor
    }

    @Test("an unchanged below-floor width spawns once the safety cap elapses")
    func belowFloorSpawnsAtSafetyCap() {
        var state = ColdStartSurfaceCreationState()

        let early = ColdStartSurfaceCreationPolicy.decision(
            state: &state, width: floor - 156, now: start
        )
        let atCap = ColdStartSurfaceCreationPolicy.decision(
            state: &state, width: floor - 156, now: start + cap
        )

        #expect(early == .wait)
        #expect(atCap == .create)
    }

    @Test("a warm pane at a real width spawns immediately")
    func warmPaneAtRealWidthSpawnsImmediately() {
        // Global cold-start ended, this pane never waited, and it's laid out
        // into the settled window at a real width — the mid-session new-tab /
        // split case. No reason to pay the settle.
        #expect(ColdStartSurfaceCreationPolicy.canSpawnImmediately(
            isColdStartPhase: false,
            paneEnteredColdStartWait: false,
            width: floor + 600
        ))
        #expect(ColdStartSurfaceCreationPolicy.canSpawnImmediately(
            isColdStartPhase: false,
            paneEnteredColdStartWait: false,
            width: floor
        ))
    }

    @Test("a late-mounting restored sibling below the floor never spawns immediately (INT-548)")
    func lateMountingSiblingBelowFloorDoesNotSpawnImmediately() {
        // The bug: on a restored split, a wider sibling spawns first and flips
        // the runtime-wide cold-start phase off. A late-mounting sibling then
        // finds `isColdStartPhase == false` while `anchorAt == nil` and its own
        // width is still the ~324pt placeholder. The old gate
        // (`guard isColdStartSurfacePhase || paneEnteredColdStartWait`) spawned
        // it immediately at that placeholder → squished ~32-col PTY. The width
        // floor must now hold it back so it routes through the settle policy.
        #expect(!ColdStartSurfaceCreationPolicy.canSpawnImmediately(
            isColdStartPhase: false,
            paneEnteredColdStartWait: false,
            width: 324
        ))
        // Even a plausible-but-still-below-floor ramp value is held back.
        #expect(!ColdStartSurfaceCreationPolicy.canSpawnImmediately(
            isColdStartPhase: false,
            paneEnteredColdStartWait: false,
            width: floor - 1
        ))
    }

    @Test("the immediate path is never taken during cold start or while a pane is settling")
    func coldStartAndSettlingPanesNeverSpawnImmediately() {
        // During the global cold-start phase every pane defers to the policy,
        // even at a wide width — the layout hasn't settled yet.
        #expect(!ColdStartSurfaceCreationPolicy.canSpawnImmediately(
            isColdStartPhase: true,
            paneEnteredColdStartWait: false,
            width: floor + 600
        ))
        // A pane that began the settle wait keeps settling on its own width even
        // after a sibling ends the global phase.
        #expect(!ColdStartSurfaceCreationPolicy.canSpawnImmediately(
            isColdStartPhase: false,
            paneEnteredColdStartWait: true,
            width: floor + 600
        ))
    }

    @Test("a growing width resets the stability clock and spawns at the final width")
    func growingWidthResetsStabilityClock() {
        // Mirrors the observed placeholder -> 739 -> 1119 ramp: each change
        // restarts the settle so the spawn lands on the width that holds.
        var state = ColdStartSurfaceCreationState()

        // Placeholder below the floor: waiting.
        _ = ColdStartSurfaceCreationPolicy.decision(
            state: &state, width: floor - 156, now: start
        )
        // First plausible width arrives.
        let firstPlausible = ColdStartSurfaceCreationPolicy.decision(
            state: &state, width: floor + 100, now: start + .milliseconds(300)
        )
        // It grows again before the stability window elapses — clock resets.
        let grew = ColdStartSurfaceCreationPolicy.decision(
            state: &state, width: floor + 480, now: start + .milliseconds(300) + stability / 2
        )
        // The final width has now held for the full stability interval.
        let settled = ColdStartSurfaceCreationPolicy.decision(
            state: &state, width: floor + 480, now: start + .milliseconds(300) + stability + stability / 2
        )

        #expect(firstPlausible == .wait)
        #expect(grew == .wait)
        #expect(settled == .create)
        #expect(state.lastObservedWidth == floor + 480)
    }
}
