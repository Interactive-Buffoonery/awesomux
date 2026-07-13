import AppKit
import AwesoMuxCore
import Testing
@testable import awesoMux

@MainActor
@Suite("Ghostty surface mouse focus monitor")
struct GhosttySurfaceMouseFocusMonitorTests {
    @Test("hit test resolves the surface under the click")
    func hitTestResolvesSurface() {
        let fixture = makeFixture()
        defer { fixture.runtime.discardAllSurfaces() }
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let surfaceView = makeSurfaceView(runtime: fixture.runtime, fixture: fixture)
        surfaceView.frame = NSRect(x: 40, y: 50, width: 200, height: 120)
        contentView.addSubview(surfaceView)

        let target = GhosttySurfaceMouseFocusMonitor.targetSurfaceView(
            in: contentView,
            at: NSPoint(x: 80, y: 90)
        )

        #expect(target === surfaceView)
    }

    @Test("hit test ignores overlay clicks above a surface")
    func hitTestIgnoresOverlayClicks() {
        let fixture = makeFixture()
        defer { fixture.runtime.discardAllSurfaces() }
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let surfaceView = makeSurfaceView(runtime: fixture.runtime, fixture: fixture)
        surfaceView.frame = NSRect(x: 40, y: 50, width: 200, height: 120)
        contentView.addSubview(surfaceView)

        let overlay = NSView(frame: surfaceView.frame)
        contentView.addSubview(overlay)

        let target = GhosttySurfaceMouseFocusMonitor.targetSurfaceView(
            in: contentView,
            at: NSPoint(x: 80, y: 90)
        )

        #expect(target == nil)
    }

    @Test("window hit test is not Y-mirrored by a flipped content view")
    func windowHitTestHandlesFlippedContentView() {
        let fixture = makeFixture()
        defer { fixture.runtime.discardAllSurfaces() }
        // Models the real window: SwiftUI's NSHostingView content view is
        // FLIPPED. The old code converted locationInWindow into contentView-
        // local coords and fed that to hitTest (which expects superview
        // coords), Y-mirroring the probe — a click on top chrome resolved
        // the surface sitting near the window bottom and stole pane focus.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Default true + ARC = over-release crash when close() runs.
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let contentView = FlippedContentView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = contentView

        let surfaceView = makeSurfaceView(runtime: fixture.runtime, fixture: fixture)
        // Bottom of the window in flipped (top-origin) coordinates.
        surfaceView.frame = NSRect(x: 40, y: 190, width: 200, height: 100)
        contentView.addSubview(surfaceView)

        // Click on top chrome (window coords are bottom-origin, so y=275 is
        // 25pt from the top). The mirrored probe would land inside the
        // surface; the correct probe must resolve nothing.
        let chromeClick = GhosttySurfaceMouseFocusMonitor.targetSurfaceView(
            in: window,
            locationInWindow: NSPoint(x: 80, y: 275)
        )
        #expect(chromeClick == nil)

        // Click over the surface itself (window y=30 → flipped y=270, inside
        // the surface's 190–290 band) still resolves it.
        let surfaceClick = GhosttySurfaceMouseFocusMonitor.targetSurfaceView(
            in: window,
            locationInWindow: NSPoint(x: 80, y: 30)
        )
        #expect(surfaceClick === surfaceView)
    }

    private func makeSurfaceView(
        runtime: GhosttyRuntime,
        fixture: Fixture
    ) -> GhosttySurfaceNSView {
        runtime.surfaceView(
            sessionStore: fixture.store,
            session: fixture.session,
            pane: fixture.pane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )
    }

    private func makeFixture() -> Fixture {
        let pane = TerminalPane(title: "monitor", workingDirectory: "/tmp/monitor", executionPlan: .local)
        let session = TerminalSession(
            title: "monitor",
            workingDirectory: "/tmp/monitor",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "awesoMux", sessions: [session])],
            selectedSessionID: session.id
        )
        return Fixture(
            pane: pane,
            session: session,
            store: store,
            runtime: GhosttyRuntime()
        )
    }

    private struct Fixture {
        let pane: TerminalPane
        let session: TerminalSession
        let store: SessionStore
        let runtime: GhosttyRuntime
    }
}

/// Stand-in for NSHostingView, which flips its coordinate system.
private final class FlippedContentView: NSView {
    override var isFlipped: Bool { true }
}
