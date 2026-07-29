import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

private actor FetchCompletionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

/// `ObservableStoreWriteThrottle.decide` — the trailing-edge rate limit for
/// `progressReport` (INT-587 review, findings #3/#1) and terminal-title store
/// writes. Pure, so it tests without a live `GhosttySurfaceNSView`/native
/// surface.
@Suite("ObservableStoreWriteThrottle")
struct ObservableStoreWriteThrottleTests {
    @Test("first write (no prior write) commits immediately")
    func firstWriteCommitsImmediately() {
        #expect(
            ObservableStoreWriteThrottle.decide(
                now: 100,
                lastWriteAt: nil,
                minInterval: 0.1
            ) == .writeNow)
    }

    @Test("a write outside the window commits immediately")
    func writeOutsideWindowCommitsImmediately() {
        #expect(
            ObservableStoreWriteThrottle.decide(
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
        #expect(
            ObservableStoreWriteThrottle.decide(
                now: 100.101,
                lastWriteAt: 100.0,
                minInterval: 0.1
            ) == .writeNow)
    }

    @Test("a write inside the window defers by the remaining time")
    func writeInsideWindowDefers() {
        let decision = ObservableStoreWriteThrottle.decide(
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
            guard
                case .deferBy(let delay) = ObservableStoreWriteThrottle.decide(
                    now: tick,
                    lastWriteAt: lastWriteAt,
                    minInterval: minInterval
                )
            else {
                Issue.record("expected .deferBy at tick \(tick)")
                continue
            }
            deadlines.append(tick + delay)
        }
        for deadline in deadlines {
            #expect(abs(deadline - 0.1) < 0.0001)
        }
    }

    /// Replays a title cadence through the throttle and returns how many writes
    /// actually commit.
    ///
    /// Models the WHOLE caller, not just `decide`: a deferred write is a timer
    /// that fires at `lastWriteAt + minInterval` and commits there, re-anchoring
    /// the window — so a steady stream commits repeatedly mid-stream, not only
    /// once at the end. Counting only a final trailing write overstates
    /// suppression (65.7% vs the real 58.6% at Codex's cadence), which would
    /// make this test assert behavior the app does not have. Scheduling replaces
    /// any pending item, matching `scheduleThrottledTerminalTitleWrite`.
    private func committedWrites(cadence: TimeInterval, over duration: TimeInterval, minInterval: TimeInterval)
        -> (writes: Int, titles: Int)
    {
        var writes = 0
        var titles = 0
        var lastWriteAt: TimeInterval?
        var pendingDeadline: TimeInterval?
        var now: TimeInterval = 0
        while now <= duration {
            titles += 1
            if let deadline = pendingDeadline, deadline <= now {
                writes += 1
                lastWriteAt = deadline
                pendingDeadline = nil
            }
            switch ObservableStoreWriteThrottle.decide(
                now: now,
                lastWriteAt: lastWriteAt,
                minInterval: minInterval
            ) {
            case .writeNow:
                writes += 1
                lastWriteAt = now
                pendingDeadline = nil
            case .deferBy(let delay):
                pendingDeadline = now + delay
            }
            now += cadence
        }
        return (pendingDeadline == nil ? writes : writes + 1, titles)
    }

    /// The window is only worth its complexity if it beats the cadence agents
    /// actually emit. Both numbers are measured off a real pty (2026-07-29):
    /// Codex animates an 8-frame braille spinner at a ~102ms median interval,
    /// Claude Code alternates two glyphs at ~961ms. The suppression asymmetry
    /// is the point — the win is concentrated entirely in Codex-style panes, so
    /// raising `terminalTitleStoreWriteMinInterval` past ~100ms is what earns
    /// anything at all, and a window at or above Codex's cadence is what this
    /// test exists to stop anyone from quietly reverting.
    @Test("the shipped window collapses a Codex-cadence title stream")
    func shippedWindowCollapsesCodexCadence() {
        // The SHIPPED constant, not a copy — a local literal here would let
        // someone retune the real window without failing anything.
        let shipped = GhosttySurfaceNSView.terminalTitleStoreWriteMinInterval

        let codex = committedWrites(cadence: 0.102, over: 10, minInterval: shipped)
        let codexSuppression = 1 - Double(codex.writes) / Double(codex.titles)
        // Brackets the shipped 0.25s rather than only flooring it: a window
        // small enough to stop earning its complexity fails low, and one large
        // enough to make the sidebar visibly lag a settling title fails high.
        #expect(codexSuppression > 0.5)
        #expect(codexSuppression < 0.7)

        // Claude Code's cadence is already slower than the window, so almost
        // every title takes the leading edge. Documented, not a defect: it is
        // why this throttle is not the whole fix for the sidebar's per-write
        // cost. If this starts failing, Claude Code sped its title animation up
        // and the window should be re-derived against a fresh measurement.
        let claude = committedWrites(cadence: 0.961, over: 10, minInterval: shipped)
        let claudeSuppression = 1 - Double(claude.writes) / Double(claude.titles)
        #expect(claudeSuppression < 0.1)
    }

    @Test("a window at or below the emitted cadence suppresses nothing")
    func windowBelowCadenceIsInert() {
        // The failure mode the measurement was run to rule out: a window chosen
        // from upper bounds alone can sit under the real frame interval, where
        // every title takes `.writeNow` and the throttle is pure overhead.
        // Uses a window comfortably below the cadence rather than one equal to
        // it — an exact tie is a float-accumulation artifact, not a behavior.
        let inert = committedWrites(cadence: 0.102, over: 10, minInterval: 0.05)
        #expect(inert.writes == inert.titles)
    }
}

/// `DeferredPaneEventDispatchGuard.shouldApply` — the pane-recycle guard for
/// every deferred terminal-event effect: throttled progress-report and
/// terminal-title writes, and the 15s progress auto-expiry. Verifies the exact
/// condition used at those call sites: an effect scheduled for one pane must
/// not land on a different pane if the view gets re-pointed via
/// `update(session:pane:...)` before the deferred effect fires (INT-587
/// review, finding #1).
@Suite("DeferredPaneEventDispatchGuard")
struct DeferredPaneEventDispatchGuardTests {
    @Test("suspended fetch does not apply after its surface is repointed")
    func suspendedFetchDoesNotApplyAfterRepoint() async {
        let capturedSessionID = TerminalSession.ID()
        let capturedPaneID = TerminalPane.ID()
        let gate = FetchCompletionGate()
        let completion = Task {
            await gate.wait()
            return DeferredPaneEventDispatchGuard.shouldApply(
                capturedSessionID: capturedSessionID,
                capturedPaneID: capturedPaneID,
                currentSessionID: capturedSessionID,
                currentPaneID: TerminalPane.ID()
            )
        }

        await Task.yield()
        await gate.release()

        #expect(await completion.value == false)
    }

    @Test("identical session and pane: applies")
    func identicalIdentityApplies() {
        let sessionID = TerminalSession.ID()
        let paneID = TerminalPane.ID()

        #expect(
            DeferredPaneEventDispatchGuard.shouldApply(
                capturedSessionID: sessionID,
                capturedPaneID: paneID,
                currentSessionID: sessionID,
                currentPaneID: paneID
            ))
    }

    @Test("pane changed underneath (view recycled to a different pane): does not apply")
    func paneIDChangedDoesNotApply() {
        let sessionID = TerminalSession.ID()

        #expect(
            !DeferredPaneEventDispatchGuard.shouldApply(
                capturedSessionID: sessionID,
                capturedPaneID: TerminalPane.ID(),
                currentSessionID: sessionID,
                currentPaneID: TerminalPane.ID()
            ))
    }

    @Test("session changed underneath (view re-pointed to a different workspace): does not apply")
    func sessionIDChangedDoesNotApply() {
        let paneID = TerminalPane.ID()

        #expect(
            !DeferredPaneEventDispatchGuard.shouldApply(
                capturedSessionID: TerminalSession.ID(),
                capturedPaneID: paneID,
                currentSessionID: TerminalSession.ID(),
                currentPaneID: paneID
            ))
    }
}
