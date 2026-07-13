import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

/// Regression coverage for the INT-587 pane-recycle race in
/// `GhosttyRuntime.action`'s `GHOSTTY_ACTION_PROGRESS_REPORT` case.
///
/// The bug two prior fix rounds shipped: dispatching the store write via
/// `Task { @MainActor [weak view] in view?.updateProgressReport(report) }`
/// leaves a gap between the C callback firing and the `Task` actually
/// running. `GhosttySurfaceNSView.update(session:pane:...)` can reassign
/// `self.sessionID` on the SAME, still-alive view instance in that gap (a
/// pane moved to a different session while its `TerminalPane.id` is reused —
/// see the "Re-pointing at a different session" branch in `update()`), which
/// would land the queued write on the WRONG session's pane if `updatePane`
/// read a captured-before-recycle identity.
///
/// The fix (`GhosttyRuntime.swift`, `GHOSTTY_ACTION_PROGRESS_REPORT` case)
/// replaces the `Task` with a synchronous `onMainThreadSynchronously { ... }` call, which
/// closes the gap entirely: `action()` is only ever invoked already on the
/// main thread (funneled through `ghostty_app_tick`, itself only called from
/// inside `Task { @MainActor in }` in `wakeup(_:)`), so the dispatch runs to
/// completion inline, with no suspension point for `update(session:pane:)` to
/// interleave. Nothing about the DIRECT dispatch captures identity ahead of
/// time anymore — `updateProgressReport` reads `self.sessionID`/`self.paneID`
/// live, at call time. (The SEPARATE deferred-write paths inside
/// `updateProgressReport` — the throttle's `.deferBy` branch and the 15s
/// auto-expiry timer, both in `GhosttySurfaceTerminalEvents.swift` — still
/// legitimately capture identity at schedule time and revalidate it on fire
/// via `ProgressReportDispatchGuard`; that guard is unrelated to this fix and
/// already covered by `ProgressReportDispatchGuardTests`.)
///
/// This test can't reconstruct the actual C callback (`GhosttyRuntime.action`
/// needs a live `ghostty_target_s` wrapping a real `ghostty_surface_t`, which
/// requires a live libghostty surface unavailable in a unit test — see the
/// existing `GhosttySurfaceAccessibilityValueChangeDedupeTests` note on the
/// same limitation). Instead it exercises the exact method the fixed
/// dispatch site calls (`updateProgressReport`), synchronously, on either
/// side of a real `update(session:pane:...)` recycle.
///
/// That alone isn't a strong regression test — a synchronous call bracketing
/// a recycle can't help but see current identity, whether or not the
/// underlying dispatch site is the fixed one. The second test below closes
/// that gap: it reproduces the OLD dispatch site's exact shape inline and
/// proves it actually misattributes, which is the thing that makes "closing
/// the gap" a meaningful claim rather than a tautology.
@MainActor
@Suite("Progress report survives a pane recycle")
struct ProgressReportPaneRecycleAtomicityTests {
    @Test("a write after recycle lands on the NEW session's pane, not the old one")
    func writeAfterRecycleTargetsCurrentSession() async throws {
        // `sharedPaneID` reused across sessionA/sessionB is a test-harness
        // device, not a claim that production ever holds two sessions with
        // the same live pane.id simultaneously — pane IDs are unique in
        // practice (`GhosttyRuntime.surfaceViews` is keyed by pane.id alone).
        // What this forces, faithfully: the SAME `pane.id` passed to
        // `runtime.surfaceView(...)` twice returns the SAME cached
        // `GhosttySurfaceNSView` both times (the real cache-hit path at
        // `GhosttyRuntime.swift:186`), and the second call's `update()` really
        // does reassign `self.sessionID` on that live instance — the exact
        // "still-alive, re-pointed" shape the bug report describes. Both
        // sessions stay queryable in the store afterward purely so this test
        // can assert on both sides of the reassignment in one place.
        let sharedPaneID = UUID()

        let paneInSessionA = TerminalPane(
            id: sharedPaneID,
            title: "session A pane",
            workingDirectory: "/tmp/a",
            executionPlan: .local
        )
        let sessionA = TerminalSession(
            title: "session A",
            workingDirectory: "/tmp/a",
            layout: .pane(paneInSessionA),
            activePaneID: paneInSessionA.id
        )

        let paneInSessionB = TerminalPane(
            id: sharedPaneID,
            title: "session B pane",
            workingDirectory: "/tmp/b",
            executionPlan: .local
        )
        let sessionB = TerminalSession(
            title: "session B",
            workingDirectory: "/tmp/b",
            layout: .pane(paneInSessionB),
            activePaneID: paneInSessionB.id
        )

        let store = SessionStore(
            groups: [SessionGroup(name: "awesoMux", sessions: [sessionA, sessionB])],
            selectedSessionID: sessionA.id
        )
        let runtime = GhosttyRuntime(initialCommandBridgeEnabled: true)

        // Mirrors `GhosttyRuntime.surfaceView(from:)` + `.updateProgressReport`
        // being called synchronously from `action()` — the exact call the
        // fixed `onMainThreadSynchronously` dispatch site makes.
        let view = runtime.surfaceView(
            sessionStore: store,
            session: sessionA,
            pane: paneInSessionA,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )
        view.updateProgressReport(TerminalProgressReport(state: .set, progress: 42))

        #expect(
            store.session(id: sessionA.id)?.layout.pane(id: sharedPaneID)?.progressReport
                == TerminalProgressReport(state: .set, progress: 42)
        )

        // Simulate the recycle: the SAME `TerminalPane.id` gets re-pointed at
        // session B (e.g. the pane was moved to a different session/group).
        // `surfaceView(sessionStore:...)` finds the cached view by pane.id and
        // calls `update(session:pane:...)`, which reassigns `self.sessionID`
        // on this exact instance — no new view, no deallocation.
        let recycledView = runtime.surfaceView(
            sessionStore: store,
            session: sessionB,
            pane: paneInSessionB,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )
        #expect(recycledView === view)

        // Clear the trailing-edge write throttle's window (`ProgressReportWriteThrottle`,
        // `progressReportStoreWriteMinInterval` = 0.1s) so this second call commits
        // immediately via `.writeNow` instead of deferring through
        // `scheduleThrottledProgressReportWrite`. A deferred write is a
        // DIFFERENT, already-covered guard (`ProgressReportDispatchGuardTests`)
        // — this test is specifically about the direct/immediate path the
        // fixed `onMainThreadSynchronously` dispatch site exercises.
        try await Task.sleep(nanoseconds: 150_000_000)

        recycledView.updateProgressReport(TerminalProgressReport(state: .set, progress: 7))

        // The new write lands on session B — the view's CURRENT identity —
        // never on session A, which is exactly the invariant a captured,
        // pre-recycle identity (the old `Task { @MainActor [weak view] }`
        // shape, had it read identity async) could have violated.
        #expect(
            store.session(id: sessionB.id)?.layout.pane(id: sharedPaneID)?.progressReport
                == TerminalProgressReport(state: .set, progress: 7)
        )
        // Session A's pane keeps its own, untouched-by-the-recycled-write value.
        #expect(
            store.session(id: sessionA.id)?.layout.pane(id: sharedPaneID)?.progressReport
                == TerminalProgressReport(state: .set, progress: 42)
        )
    }

    @Test("the OLD Task-based dispatch shape actually misattributes across a recycle")
    func oldAsyncDispatchShapeMisattributesAcrossRecycle() async throws {
        // This test exists because a synchronous call bracketing a recycle
        // (the test above) would pass regardless of which dispatch site
        // produced it — it doesn't distinguish "fixed" from "still buggy."
        // To make that distinction, this test reproduces the OLD dispatch
        // site's exact shape verbatim — `Task { @MainActor [weak view] in
        // view?.updateProgressReport(report) }` — and proves it lands a
        // report on the WRONG session when a recycle interleaves.
        let sharedPaneID = UUID()

        let paneInSessionA = TerminalPane(
            id: sharedPaneID,
            title: "session A pane",
            workingDirectory: "/tmp/a",
            executionPlan: .local
        )
        let sessionA = TerminalSession(
            title: "session A",
            workingDirectory: "/tmp/a",
            layout: .pane(paneInSessionA),
            activePaneID: paneInSessionA.id
        )

        let paneInSessionB = TerminalPane(
            id: sharedPaneID,
            title: "session B pane",
            workingDirectory: "/tmp/b",
            executionPlan: .local
        )
        let sessionB = TerminalSession(
            title: "session B",
            workingDirectory: "/tmp/b",
            layout: .pane(paneInSessionB),
            activePaneID: paneInSessionB.id
        )

        let store = SessionStore(
            groups: [SessionGroup(name: "awesoMux", sessions: [sessionA, sessionB])],
            selectedSessionID: sessionA.id
        )
        let runtime = GhosttyRuntime(initialCommandBridgeEnabled: true)

        let view = runtime.surfaceView(
            sessionStore: store,
            session: sessionA,
            pane: paneInSessionA,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )

        // Reproduces `GhosttyRuntime.action`'s pre-fix
        // `GHOSTTY_ACTION_PROGRESS_REPORT` case verbatim: a report meant for
        // pane A's current identity, queued via `Task { @MainActor [weak
        // view] }` instead of dispatched inline.
        //
        // Swift's cooperative scheduling guarantees this child `Task` does
        // NOT run until the CURRENTLY-EXECUTING (non-suspended) code below
        // hits a suspension point — so the recycle a few lines down is
        // guaranteed to land BEFORE the task body runs, deterministically
        // modeling the real gap between the C callback firing and the
        // queued `Task` actually executing. No sleep, no flakiness.
        let reportMeantForSessionA = TerminalProgressReport(state: .set, progress: 99)
        let oldShapeDispatch = Task { @MainActor [weak view] in
            view?.updateProgressReport(reportMeantForSessionA)
        }

        // The recycle happens in the gap — same as `update(session:pane:...)`
        // firing on a live SwiftUI re-render before the queued Task gets a
        // turn on the main actor.
        let recycledView = runtime.surfaceView(
            sessionStore: store,
            session: sessionB,
            pane: paneInSessionB,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )
        #expect(recycledView === view)

        await oldShapeDispatch.value

        // The bug, reproduced: a report meant for session A's pane lands on
        // session B instead, because the queued Task only read
        // `view.sessionID`/`view.paneID` AFTER the recycle reassigned them.
        #expect(
            store.session(id: sessionB.id)?.layout.pane(id: sharedPaneID)?.progressReport
                == reportMeantForSessionA
        )
        #expect(
            store.session(id: sessionA.id)?.layout.pane(id: sharedPaneID)?.progressReport
                == nil
        )
    }

    @Test("onMainThreadSynchronously's off-main fallback returns the correct value without deadlocking")
    func onMainThreadOffMainFallbackIsSafe() async {
        // Neither test above can reach `onMainThreadSynchronously`'s
        // `DispatchQueue.main.sync` fallback branch — both call
        // `updateProgressReport` directly, already on the main actor. This
        // codebase's call-graph analysis concludes that branch should never
        // execute in production for progress-report dispatch specifically
        // (see the comment at the call site in `GhosttyRuntime.swift`), but
        // "should never execute" is a claim about the CALLER, not a
        // guarantee that the branch itself is correct if something ever
        // does call it off-main. This exercises it directly, from a real
        // background thread.
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let value = onMainThreadSynchronously { 42 }
                continuation.resume(returning: value)
            }
        }
        #expect(result == 42)
    }
}
