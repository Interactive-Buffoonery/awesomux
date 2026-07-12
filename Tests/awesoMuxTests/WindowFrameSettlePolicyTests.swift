import CoreGraphics
import Foundation
import Testing
@testable import awesoMux

@Suite("Window frame settle policy")
struct WindowFrameSettlePolicyTests {
    private let settle = WindowFrameSettlePolicy.settleInterval
    private let cap = WindowFrameSettlePolicy.safetyCapInterval
    private let start = ContinuousClock.now
    private let frameA = CGRect(x: 0, y: 0, width: 1280, height: 820)
    private let frameB = CGRect(x: 0, y: 0, width: 2490, height: 1399)

    @Test("a freshly observed frame always waits at least the settle interval")
    func freshFrameWaits() {
        var state = WindowFrameSettleState()

        let first = WindowFrameSettlePolicy.decision(
            state: &state, windowFrame: frameA, now: start
        )
        let beforeSettled = WindowFrameSettlePolicy.decision(
            state: &state, windowFrame: frameA, now: start + settle / 2
        )

        #expect(first == .wait)
        #expect(beforeSettled == .wait)
    }

    @Test("an unchanged frame proceeds once it has held for the settle interval")
    func unchangedFrameProceeds() {
        var state = WindowFrameSettleState()

        _ = WindowFrameSettlePolicy.decision(state: &state, windowFrame: frameA, now: start)
        let settled = WindowFrameSettlePolicy.decision(
            state: &state, windowFrame: frameA, now: start + settle
        )

        #expect(settled == .proceed)
    }

    @Test("a frame change restarts the settle clock so the spawn lands on the final frame")
    func frameChangeRestartsClock() {
        // The launch ramp: window starts at one frame, then placement/layout
        // lands on a wider frame. The change must reset the settle so the spawn
        // waits for the final frame, not the placeholder.
        var state = WindowFrameSettleState()

        _ = WindowFrameSettlePolicy.decision(state: &state, windowFrame: frameA, now: start)
        // The frame would have settled here had it not changed...
        let ramped = WindowFrameSettlePolicy.decision(
            state: &state, windowFrame: frameB, now: start + settle - .milliseconds(50)
        )
        // ...but the change reset the clock, so just-short-of-settle still waits.
        let stillWaiting = WindowFrameSettlePolicy.decision(
            state: &state, windowFrame: frameB, now: start + settle - .milliseconds(50) + settle / 2
        )
        // The final frame has now held for the full settle interval.
        let settled = WindowFrameSettlePolicy.decision(
            state: &state, windowFrame: frameB, now: start + settle - .milliseconds(50) + settle
        )

        #expect(ramped == .wait)
        #expect(stillWaiting == .wait)
        #expect(settled == .proceed)
        #expect(state.lastFrame == frameB)
    }

    @Test("a frame that never quiesces proceeds once the safety cap elapses")
    func neverQuiescesProceedsAtCap() {
        // A tiling WM nudging the window every tick must not strand the pane.
        var state = WindowFrameSettleState()
        var width = 1280.0

        // Change the frame on every poll, faster than the settle interval, right
        // up to the cap. Each change resets the settle clock, so only the cap
        // can release it.
        var now = start
        let step = Duration.milliseconds(50)
        var lastDecision = WindowFrameSettleDecision.wait
        while now - start < cap {
            width += 1
            let frame = CGRect(x: 0, y: 0, width: width, height: 820)
            lastDecision = WindowFrameSettlePolicy.decision(state: &state, windowFrame: frame, now: now)
            #expect(lastDecision == .wait)
            now = now + step
        }

        // At/after the cap, it proceeds despite the frame still changing.
        width += 1
        let atCap = WindowFrameSettlePolicy.decision(
            state: &state,
            windowFrame: CGRect(x: 0, y: 0, width: width, height: 820),
            now: start + cap
        )
        #expect(atCap == .proceed)
    }
}
