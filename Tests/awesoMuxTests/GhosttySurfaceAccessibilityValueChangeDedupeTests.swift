import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

/// Regression coverage for a bug found (and fixed) during review: an earlier
/// version of `disposeNativeSurface()` reset `lastAccessibilityReportedVisibleText`
/// but not `lastDetectedVisibleText`, which is the OUTER dedupe gate in
/// `sampleAgentStateFromVisibleText()` (`GhosttySurfaceTerminalEvents.swift`) —
/// it's checked first and returns early on a match, so the inner reset was
/// unreachable in exactly the scenario it was written for: a same-instance
/// surface respawn (command-bridge heal, local-shell fallback) whose first
/// sampled text happens to match the prior surface's last-sampled text (e.g.
/// both idle at an empty prompt).
///
/// This doesn't exercise `sampleAgentStateFromVisibleText()` itself — that
/// needs a live `ghostty_surface_t`, which isn't available in a unit test —
/// but it directly exercises the state `disposeNativeSurface()` is
/// responsible for resetting, which is exactly what a same-instance respawn
/// relies on.
@MainActor
@Suite("GhosttySurfaceNSView accessibility value-change dedupe reset")
struct GhosttySurfaceAccessibilityValueChangeDedupeTests {
    @Test("disposeNativeSurface() resets both halves of the sampler's dedupe gate")
    func disposeResetsBothDedupeFields() throws {
        let view = try makeView()

        // Simulate a surface that already sampled and reported some text —
        // the state a live session accumulates before a respawn.
        view.lastDetectedVisibleText = "user@host:~$ "
        view.lastAccessibilityReportedVisibleText = "user@host:~$ "

        view.disposeNativeSurface()

        // Both must reset together: if only one does, a respawned surface
        // whose first sample matches the old text gets silently swallowed by
        // whichever gate still holds the stale value.
        #expect(view.lastDetectedVisibleText == "")
        #expect(view.lastAccessibilityReportedVisibleText == nil)
    }

    @Test("disposeNativeSurface() reset is idempotent with no native surface present")
    func disposeResetIsSafeWithoutSurface() throws {
        // The view under test never calls createSurfaceIfNeeded(), so
        // `surface` is nil here — disposeNativeSurface() must still run its
        // side-effect resets and return early afterward, not skip them.
        let view = try makeView()
        view.lastDetectedVisibleText = "stale"
        view.lastAccessibilityReportedVisibleText = "stale"

        view.disposeNativeSurface()
        view.disposeNativeSurface()

        #expect(view.lastDetectedVisibleText == "")
        #expect(view.lastAccessibilityReportedVisibleText == nil)
    }

    private func makeView() throws -> GhosttySurfaceNSView {
        let sessionID = try #require(TerminalSessionID(
            rawValue: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        ))
        let pane = TerminalPane(
            terminalSessionID: sessionID,
            title: "test pane",
            workingDirectory: "/tmp/test"
        )
        let session = TerminalSession(
            title: "test session",
            workingDirectory: "/tmp/test",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "awesoMux", sessions: [session])],
            selectedSessionID: session.id
        )
        let runtime = GhosttyRuntime(initialCommandBridgeEnabled: true)
        return runtime.surfaceView(
            sessionStore: store,
            session: session,
            pane: pane,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )
    }
}
