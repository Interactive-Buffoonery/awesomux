import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

/// `ProgressReportWriteThrottle.decide` — the trailing-edge rate limit for
/// `progressReport` store writes (INT-587 review, findings #3/#1). Pure, so
/// it tests without a live `GhosttySurfaceNSView`/native surface.
@Suite("ProgressReportWriteThrottle")
struct ProgressReportWriteThrottleTests {
    @Test("first write (no prior write) commits immediately")
    func firstWriteCommitsImmediately() {
        #expect(ProgressReportWriteThrottle.decide(
            now: 100,
            lastWriteAt: nil,
            minInterval: 0.1
        ) == .writeNow)
    }

    @Test("a write outside the window commits immediately")
    func writeOutsideWindowCommitsImmediately() {
        #expect(ProgressReportWriteThrottle.decide(
            now: 100.2,
            lastWriteAt: 100.0,
            minInterval: 0.1
        ) == .writeNow)
    }

    @Test("a write just past the window boundary commits immediately")
    func writeJustPastBoundaryCommitsImmediately() {
        // `100.0 + 0.1` lands a hair under `100.1` in binary floating point,
        // so this asserts on a value unambiguously past the boundary rather
        // than an exact tie (which is inherently float-imprecise, not a
        // meaningful throttle behavior to pin down).
        #expect(ProgressReportWriteThrottle.decide(
            now: 100.101,
            lastWriteAt: 100.0,
            minInterval: 0.1
        ) == .writeNow)
    }

    @Test("a write inside the window defers by the remaining time")
    func writeInsideWindowDefers() {
        let decision = ProgressReportWriteThrottle.decide(
            now: 100.03,
            lastWriteAt: 100.0,
            minInterval: 0.1
        )
        guard case .deferBy(let delay) = decision else {
            Issue.record("expected .deferBy, got \(decision)")
            return
        }
        #expect(abs(delay - 0.07) < 0.0001)
    }

    @Test("repeated fast ticks keep recomputing toward the SAME deadline, not extending it")
    func fastTicksConvergeOnSameDeadline() {
        // A tick every 10ms starting right after a write at t=0 — each
        // recomputed delay should land on the same absolute deadline
        // (t=100ms), proving this is a throttle (bounded max delay) and not
        // an unbounded debounce that never flushes under sustained input.
        let lastWriteAt: TimeInterval = 0
        let minInterval: TimeInterval = 0.1
        var deadlines: [TimeInterval] = []
        for tick in stride(from: 0.01, through: 0.09, by: 0.01) {
            guard case .deferBy(let delay) = ProgressReportWriteThrottle.decide(
                now: tick,
                lastWriteAt: lastWriteAt,
                minInterval: minInterval
            ) else {
                Issue.record("expected .deferBy at tick \(tick)")
                continue
            }
            deadlines.append(tick + delay)
        }
        for deadline in deadlines {
            #expect(abs(deadline - 0.1) < 0.0001)
        }
    }
}

/// `ProgressReportDispatchGuard.shouldApply` — the pane-recycle guard for
/// deferred progress-report effects (throttled writes, the 15s auto-expiry).
/// Verifies the exact condition used at both call sites in
/// `GhosttySurfaceTerminalEvents.updateProgressReport`: a report scheduled
/// for one pane must not land on a different pane if the view gets
/// re-pointed via `update(session:pane:...)` before the deferred effect
/// fires (INT-587 review, finding #1).
@Suite("ProgressReportDispatchGuard")
struct ProgressReportDispatchGuardTests {
    @Test("identical session and pane: applies")
    func identicalIdentityApplies() {
        let sessionID = TerminalSession.ID()
        let paneID = TerminalPane.ID()

        #expect(ProgressReportDispatchGuard.shouldApply(
            capturedSessionID: sessionID,
            capturedPaneID: paneID,
            currentSessionID: sessionID,
            currentPaneID: paneID
        ))
    }

    @Test("pane changed underneath (view recycled to a different pane): does not apply")
    func paneIDChangedDoesNotApply() {
        let sessionID = TerminalSession.ID()

        #expect(!ProgressReportDispatchGuard.shouldApply(
            capturedSessionID: sessionID,
            capturedPaneID: TerminalPane.ID(),
            currentSessionID: sessionID,
            currentPaneID: TerminalPane.ID()
        ))
    }

    @Test("session changed underneath (view re-pointed to a different workspace): does not apply")
    func sessionIDChangedDoesNotApply() {
        let paneID = TerminalPane.ID()

        #expect(!ProgressReportDispatchGuard.shouldApply(
            capturedSessionID: TerminalSession.ID(),
            capturedPaneID: paneID,
            currentSessionID: TerminalSession.ID(),
            currentPaneID: paneID
        ))
    }
}
