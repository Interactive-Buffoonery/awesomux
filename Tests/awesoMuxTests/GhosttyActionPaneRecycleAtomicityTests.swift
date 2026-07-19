import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

/// Regression coverage for the INT-608 pane-recycle races in the title and
/// working-directory cases of `GhosttyRuntime.action`.
///
/// This is the INT-608 mirror of INT-587's
/// `ProgressReportPaneRecycleAtomicityTests`. The old dispatch shape queued a
/// `Task { @MainActor in ... }`, leaving a gap where
/// `GhosttySurfaceNSView.update(session:pane:...)` could repoint the SAME,
/// still-alive view to another session before the handler read its live
/// `sessionID` and `paneID`. The queued store write then landed on the wrong
/// session's pane.
///
/// As in the precedent, these tests cannot reconstruct the real C callback:
/// `GhosttyRuntime.action` needs a live `ghostty_target_s` wrapping a real
/// libghostty surface, which is unavailable in a unit test. Instead, each
/// pair exercises the exact handler called by the fixed synchronous dispatch
/// on either side of a real `runtime.surfaceView(...)` recycle, then
/// reproduces the old `Task` shape inline to prove that shape misattributes
/// deterministically.
///
/// `markNeedsAttention` (the handler behind `GHOSTTY_ACTION_RING_BELL` /
/// `GHOSTTY_ACTION_DESKTOP_NOTIFICATION`) is NOT covered here — a PR-review
/// adversarial pass found that converting those two dispatch sites alone
/// would invert their effective order relative to the still-`Task`-dispatched
/// `GHOSTTY_ACTION_COMMAND_FINISHED`, which writes the same attention fields.
/// Fixing that needs a combined change to both, tracked as a follow-up; see
/// the comments on those three cases in `GhosttyRuntimeCallbacks.swift`.
/// View-local sibling actions and the other deliberately excluded cases are
/// also outside this test's scope; see the PR description.
@MainActor
@Suite("Ghostty actions survive a pane recycle")
struct GhosttyActionPaneRecycleAtomicityTests {
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

    @Test("the old terminal-title Task shape misattributes across a recycle")
    func oldTerminalTitleTaskShapeMisattributes() async {
        let harness = makeHarness()

        // Verbatim pre-fix dispatch shape. Cooperative scheduling guarantees
        // the recycle below completes before this child task can run.
        let oldShapeDispatch = Task { @MainActor in
            harness.view.updateTerminalTitle("title meant for A")
        }
        let recycledView = recycle(harness)

        #expect(recycledView === harness.view)
        await oldShapeDispatch.value

        #expect(
            harness.store.session(id: harness.sessionA.id)?
                .layout.pane(id: harness.sharedPaneID)?.title == "session A pane"
        )
        #expect(
            harness.store.session(id: harness.sessionB.id)?
                .layout.pane(id: harness.sharedPaneID)?.title == "title meant for A"
        )
    }

    @Test("working directories stay with the session targeted at handler time")
    func workingDirectorySurvivesRecycle() {
        let harness = makeHarness()

        harness.view.updateWorkingDirectory("/tmp")
        let recycledView = recycle(harness)
        recycledView.updateWorkingDirectory("/usr")

        #expect(recycledView === harness.view)
        #expect(
            harness.store.session(id: harness.sessionA.id)?
                .layout.pane(id: harness.sharedPaneID)?.workingDirectory
                == WorkingDirectoryValidator.canonicalizedPath("/tmp")
        )
        #expect(
            harness.store.session(id: harness.sessionB.id)?
                .layout.pane(id: harness.sharedPaneID)?.workingDirectory
                == WorkingDirectoryValidator.canonicalizedPath("/usr")
        )
    }

    @Test("the old working-directory Task shape misattributes across a recycle")
    func oldWorkingDirectoryTaskShapeMisattributes() async {
        let harness = makeHarness()

        // Verbatim pre-fix dispatch shape. Cooperative scheduling guarantees
        // the recycle below completes before this child task can run.
        let oldShapeDispatch = Task { @MainActor in
            harness.view.updateWorkingDirectory("/var")
        }
        let recycledView = recycle(harness)

        #expect(recycledView === harness.view)
        await oldShapeDispatch.value

        #expect(
            harness.store.session(id: harness.sessionA.id)?
                .layout.pane(id: harness.sharedPaneID)?.workingDirectory == "/tmp/a"
        )
        #expect(
            harness.store.session(id: harness.sessionB.id)?
                .layout.pane(id: harness.sharedPaneID)?.workingDirectory
                == WorkingDirectoryValidator.canonicalizedPath("/var")
        )
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
            paneInSessionB: paneInSessionB,
            sessionA: sessionA,
            sessionB: sessionB,
            store: store,
            runtime: runtime,
            view: view
        )
    }

    private func recycle(_ harness: PaneRecycleHarness) -> GhosttySurfaceNSView {
        harness.runtime.surfaceView(
            sessionStore: harness.store,
            session: harness.sessionB,
            pane: harness.paneInSessionB,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )
    }
}

@MainActor
private struct PaneRecycleHarness {
    let sharedPaneID: UUID
    let paneInSessionB: TerminalPane
    let sessionA: TerminalSession
    let sessionB: TerminalSession
    let store: SessionStore
    let runtime: GhosttyRuntime
    let view: GhosttySurfaceNSView
}
