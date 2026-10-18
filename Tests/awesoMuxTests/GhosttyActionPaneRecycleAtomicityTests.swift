import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

/// Exercises title and progress writes across real cached-view repoints.
/// The native Ghostty callback itself still requires a live terminal surface.
@MainActor
@Suite("Ghostty actions survive a pane recycle", .serialized)
struct GhosttyActionPaneRecycleAtomicityTests {
    @Test("rapid terminal titles collapse to the latest trailing write")
    func rapidTerminalTitlesCollapseToLatestTrailingWrite() async throws {
        let harness = makeHarness()

        harness.view.updateTerminalTitle("⠋ awesomux")
        harness.view.updateTerminalTitle("⠙ awesomux")
        harness.view.updateTerminalTitle("⠹ awesomux")

        #expect(
            harness.store.session(id: harness.sessionA.id)?
                .layout.pane(id: harness.sharedPaneID)?.title == "⠋ awesomux"
        )

        try await Task.sleep(for: .seconds(GhosttySurfaceNSView.terminalTitleStoreWriteMinInterval * 3))

        #expect(
            harness.store.session(id: harness.sessionA.id)?
                .layout.pane(id: harness.sharedPaneID)?.title == "⠹ awesomux"
        )
    }

    @Test("a deferred terminal title never lands on the recycled-in pane")
    func deferredTerminalTitleNeverLandsOnRecycledInPane() async throws {
        let harness = makeHarness()

        harness.view.updateTerminalTitle("title written to A")
        harness.view.updateTerminalTitle("deferred title meant for A")
        let recycledView = recycle(harness)
        recycledView.updateTerminalTitle("title written to B")

        #expect(recycledView === harness.view)

        try await Task.sleep(for: .seconds(GhosttySurfaceNSView.terminalTitleStoreWriteMinInterval * 3))

        // A's deferred write must not reach B under any route — it is cancelled
        // when B supersedes the slot, and the guard would drop it regardless.
        #expect(
            harness.store.session(id: harness.sessionB.id)?
                .layout.pane(id: harness.sharedPaneID)?.title == "title written to B"
        )
        #expect(
            harness.store.session(id: harness.sessionA.id)?
                .layout.pane(id: harness.sharedPaneID)?.title == "title written to A"
        )
    }

    @Test("a pending terminal title is flushed when the surface is torn down")
    func pendingTerminalTitleSurvivesTeardown() {
        let harness = makeHarness()

        harness.view.updateTerminalTitle("title written to A")
        harness.view.updateTerminalTitle("final title for A")
        harness.view.flushTerminalTitleThrottle()

        // The command-bridge heal disposes the surface while the pane lives on,
        // so the pending title must land rather than be cancelled.
        #expect(
            harness.store.session(id: harness.sessionA.id)?
                .layout.pane(id: harness.sharedPaneID)?.title == "final title for A"
        )
    }

    @Test("a flushed title does not fire again and clobber a newer title")
    func flushedTerminalTitleDoesNotRefireAfterFlush() async throws {
        let harness = makeHarness()

        harness.view.updateTerminalTitle("title written to A")
        harness.view.updateTerminalTitle("deferred title for A")
        harness.view.flushTerminalTitleThrottle()
        harness.view.updateTerminalTitle("newest title for A")

        // Past the flushed item's original deadline: `perform()` alone does not
        // consume the pending `asyncAfter`, so without `cancel()` the stale
        // deferred title lands here and overwrites the newest one.
        try await Task.sleep(for: .seconds(GhosttySurfaceNSView.terminalTitleStoreWriteMinInterval * 3))

        #expect(
            harness.store.session(id: harness.sessionA.id)?
                .layout.pane(id: harness.sharedPaneID)?.title == "newest title for A"
        )
    }

    @Test("an orphaned pending title cannot land after the view returns to its pane")
    func orphanedPendingTitleDoesNotLandOnRepointBack() async throws {
        let harness = makeHarness()

        harness.view.updateTerminalTitle("title written to A")
        harness.view.updateTerminalTitle("orphaned title for A")

        // B supersedes the slot. Cancelling only a write this pane OWNS left A's
        // item queued but untracked, because B overwrites the slot regardless.
        let recycledView = recycle(harness)
        recycledView.updateTerminalTitle("title written to B")
        recycledView.updateTerminalTitle("deferred title for B")

        let restoredView = repointBackToA(harness)
        restoredView.updateTerminalTitle("newest title for A")
        #expect(restoredView === harness.view)

        try await Task.sleep(for: .seconds(GhosttySurfaceNSView.terminalTitleStoreWriteMinInterval * 3))

        // The orphan's guard passes again once the view points back at A, so an
        // uncancelled item commits a title two events stale over the newest one.
        #expect(
            harness.store.session(id: harness.sessionA.id)?
                .layout.pane(id: harness.sharedPaneID)?.title == "newest title for A"
        )
        #expect(
            harness.store.session(id: harness.sessionB.id)?
                .layout.pane(id: harness.sharedPaneID)?.title == "title written to B"
        )
    }

    @Test("terminal titles stay with the session targeted at handler time")
    func terminalTitleSurvivesRecycle() {
        let harness = makeHarness()

        harness.view.updateTerminalTitle("title written to A")
        let recycledView = recycle(harness)
        recycledView.updateTerminalTitle("title written to B")

        #expect(recycledView === harness.view)
        #expect(
            harness.store.session(id: harness.sessionA.id)?
                .layout.pane(id: harness.sharedPaneID)?.title == "title written to A"
        )
        #expect(
            harness.store.session(id: harness.sessionB.id)?
                .layout.pane(id: harness.sharedPaneID)?.title == "title written to B"
        )
    }

    @Test("a progress write after recycle targets the current session")
    func writeAfterRecycleTargetsCurrentSession() async throws {
        let harness = makeHarness()
        let initial = TerminalProgressReport(state: .set, progress: 42)
        let current = TerminalProgressReport(state: .set, progress: 7)
        harness.view.updateProgressReport(initial)
        #expect(harness.store.session(id: harness.sessionA.id)?.layout.pane(id: harness.sharedPaneID)?.progressReport == initial)
        harness.view.updateProgressReport(TerminalProgressReport(state: .set, progress: 43))
        let recycled = recycle(harness)
        #expect(recycled === harness.view)
        recycled.updateProgressReport(current)
        #expect(harness.store.session(id: harness.sessionB.id)?.layout.pane(id: harness.sharedPaneID)?.progressReport == current)
        #expect(harness.store.session(id: harness.sessionA.id)?.layout.pane(id: harness.sharedPaneID)?.progressReport == initial)
        #expect(repointBackToA(harness) === harness.view)
        // Cross the original trailing deadline so an orphan cannot false-pass before it fires.
        try await Task.sleep(for: .seconds(GhosttySurfaceNSView.progressReportStoreWriteMinInterval * 3))
        #expect(harness.store.session(id: harness.sessionA.id)?.layout.pane(id: harness.sharedPaneID)?.progressReport == initial)
        #expect(harness.store.session(id: harness.sessionB.id)?.layout.pane(id: harness.sharedPaneID)?.progressReport == current)
    }

    private func makeHarness() -> PaneRecycleHarness {
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
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )

        return PaneRecycleHarness(
            sharedPaneID: sharedPaneID,
            paneInSessionA: paneInSessionA,
            paneInSessionB: paneInSessionB,
            sessionA: sessionA,
            sessionB: sessionB,
            store: store,
            runtime: runtime,
            view: view
        )
    }

    private func recycle(_ harness: PaneRecycleHarness) -> GhosttySurfaceNSView {
        repoint(harness, to: harness.sessionB, pane: harness.paneInSessionB)
    }

    private func repointBackToA(_ harness: PaneRecycleHarness) -> GhosttySurfaceNSView {
        repoint(harness, to: harness.sessionA, pane: harness.paneInSessionA)
    }

    private func repoint(
        _ harness: PaneRecycleHarness,
        to session: TerminalSession,
        pane: TerminalPane
    ) -> GhosttySurfaceNSView {
        harness.runtime.surfaceView(
            sessionStore: harness.store,
            session: session,
            pane: pane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )
    }
}

@MainActor
private struct PaneRecycleHarness {
    let sharedPaneID: UUID
    let paneInSessionA: TerminalPane
    let paneInSessionB: TerminalPane
    let sessionA: TerminalSession
    let sessionB: TerminalSession
    let store: SessionStore
    let runtime: GhosttyRuntime
    let view: GhosttySurfaceNSView
}
