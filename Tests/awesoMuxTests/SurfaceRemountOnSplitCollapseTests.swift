import AppKit
import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

/// INT-600: collapsing a split (`.split(A, B)` → `.pane(A)`) forces SwiftUI to
/// destroy the survivor's old container and remount the cached
/// `GhosttySurfaceNSView` into a fresh one. Live diagnosis showed the outgoing
/// split subtree can update AFTER the surviving container, stealing the
/// survivor into a container that is then dismantled — leaving the view
/// orphaned with its renderer paused. These tests drive that AppKit remount
/// path headlessly: the window is never ordered front, so no native libghostty
/// surface spawns and the assertions target the remount contracts (reparent,
/// backing-state invalidation, focus handoff, orphan-rescue nudge).
@MainActor
@Suite("Surface remount on split collapse")
struct SurfaceRemountOnSplitCollapseTests {
    @Test("collapse remount reparents the survivor into the fresh container")
    func collapseRemountReparentsSurvivorIntoFreshContainer() throws {
        let fixture = try makeSplitFixture()
        let window = makeWindow()
        defer { window.close() }
        let runtime = GhosttyRuntime()
        defer { runtime.discardAllSurfaces() }
        let survivorView = makeSurvivorView(runtime: runtime, fixture: fixture)

        let oldContainer = mountContainer(in: window)
        oldContainer.mount(survivorView, isActive: false, contentSize: paneSize)
        #expect(survivorView.window === window)

        let freshContainer = mountContainer(in: window)
        freshContainer.mount(survivorView, isActive: true, contentSize: paneSize)
        runtime.discardSurface(for: fixture.deadPane.id)

        #expect(survivorView.window === window)
        #expect(survivorView.isDescendant(of: freshContainer))
        #expect(!survivorView.isDescendant(of: oldContainer))
        // The AT-facing contract of the same remount: the fresh container
        // re-labels itself for the now-active survivor.
        #expect(freshContainer.accessibilityLabel()?.hasPrefix("Active terminal pane") == true)
    }

    @Test("a closed pane's stale render pass does not resurrect its surface view")
    func closedPaneStaleRenderPassDoesNotResurrectSurfaceView() throws {
        let fixture = try makeSplitFixture()

        #expect(GhosttySurfaceRepresentable.paneIsLive(
            paneID: fixture.deadPane.id,
            sessionID: fixture.session.id,
            in: fixture.store
        ))

        // The real close ordering: the store drops the pane, the surface is
        // discarded, and only then can the stale outgoing split pass run its
        // updateNSView with the old layout values. The liveness gate is what
        // stops that pass from re-creating (and re-caching) a surface view —
        // and, on a visible window, respawning a shell — for the dead pane.
        _ = fixture.store.closePane(id: fixture.deadPane.id, in: fixture.session.id)

        #expect(!GhosttySurfaceRepresentable.paneIsLive(
            paneID: fixture.deadPane.id,
            sessionID: fixture.session.id,
            in: fixture.store
        ))
        #expect(GhosttySurfaceRepresentable.paneIsLive(
            paneID: fixture.siblingPane.id,
            sessionID: fixture.session.id,
            in: fixture.store
        ))
    }

    @Test("remount into a fresh container invalidates the applied backing state")
    func remountInvalidatesAppliedBackingStateForRepush() throws {
        let fixture = try makeSplitFixture()
        let window = makeWindow()
        defer { window.close() }
        let runtime = GhosttyRuntime()
        defer { runtime.discardAllSurfaces() }
        let survivorView = makeSurvivorView(runtime: runtime, fixture: fixture)

        let oldContainer = mountContainer(in: window)
        oldContainer.mount(survivorView, isActive: false, contentSize: paneSize)
        // Stand in for the state a live surface would have pushed before the
        // collapse. Headless (no native surface) the re-push is guarded out,
        // so the observable contract is: a remount leaves `nil`, forcing the
        // next size update onto the applyImmediately path that re-pushes
        // scale, size, and occlusion to libghostty.
        survivorView.lastAppliedSurfaceBackingState = SurfaceBackingState(
            geometry: SurfaceBackingGeometry(
                pointSize: CGSize(width: 400, height: 300),
                backingScale: 2
            ),
            isVisible: true
        )

        let freshContainer = mountContainer(in: window)
        freshContainer.mount(survivorView, isActive: true, contentSize: paneSize)

        #expect(survivorView.lastAppliedSurfaceBackingState == nil)
    }

    @Test("native teardown replaces a stale hosted render layer")
    func nativeTeardownReplacesStaleHostedRenderLayer() throws {
        let fixture = try makeSplitFixture()
        let window = makeWindow()
        defer { window.close() }
        let runtime = GhosttyRuntime()
        defer { runtime.discardAllSurfaces() }
        let surfaceView = makeSurvivorView(runtime: runtime, fixture: fixture)

        let container = mountContainer(in: window)
        container.mount(surfaceView, isActive: true, contentSize: paneSize)
        let hostedLayer = CALayer()
        hostedLayer.contentsScale = 2
        hostedLayer.contents = NSImage(size: NSSize(width: 12, height: 12))
        surfaceView.layer = hostedLayer
        surfaceView.wantsLayer = true

        surfaceView.resetLayerAfterNativeSurfaceTeardown()

        #expect(surfaceView.layer !== hostedLayer)
        #expect(hostedLayer.superlayer == nil)
        #expect(surfaceView.layer?.needsDisplayOnBoundsChange == true)
        let expectedBackgroundColor = TerminalBackstopBackground
            .color(for: runtime.resolvedTerminalBackgroundHex())?
            .cgColor
        #expect(surfaceView.layer?.backgroundColor == expectedBackgroundColor)
        #expect(surfaceView.layer?.contentsScale == window.backingScaleFactor)
    }

    @Test("collapse hands focus from the closed pane's view to the survivor")
    func collapseLeavesNoVacantFirstResponder() throws {
        // The user closes the pane they're focused in — the reported INT-600
        // shape — so the CLOSED pane is the active one here.
        let fixture = try makeSplitFixture(deadPaneIsActive: true)
        let window = makeWindow()
        defer { window.close() }
        let runtime = GhosttyRuntime()
        defer { runtime.discardAllSurfaces() }
        let deadView = runtime.surfaceView(
            sessionStore: fixture.store,
            session: fixture.session,
            pane: fixture.deadPane,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )
        let survivorView = makeSurvivorView(runtime: runtime, fixture: fixture)

        let deadContainer = mountContainer(in: window)
        deadContainer.mount(deadView, isActive: true, contentSize: paneSize)
        let survivorContainer = mountContainer(in: window)
        survivorContainer.mount(survivorView, isActive: false, contentSize: paneSize)
        #expect(window.firstResponder === deadView)

        runtime.discardSurface(for: fixture.deadPane.id)
        let freshContainer = mountContainer(in: window)
        freshContainer.mount(survivorView, isActive: true, contentSize: paneSize)

        #expect(window.firstResponder === survivorView)
    }

    @Test("a repeat mount reclaims a vacant first responder for the active pane")
    func repeatMountReclaimsVacantFocusForActivePane() throws {
        let fixture = try makeSplitFixture()
        let window = makeWindow()
        defer { window.close() }
        let runtime = GhosttyRuntime()
        defer { runtime.discardAllSurfaces() }
        let survivorView = makeSurvivorView(runtime: runtime, fixture: fixture)

        let container = mountContainer(in: window)
        container.mount(survivorView, isActive: true, contentSize: paneSize)
        #expect(window.firstResponder === survivorView)

        // A collapse can leave the responder vacant (the closed pane's view was
        // focused and is gone) on a mount where the survivor is both already
        // mounted and already active — the case the old edge-gated reclaim
        // skipped (INT-562 recurrence family).
        window.makeFirstResponder(nil)
        #expect(window.firstResponder !== survivorView)

        container.mount(survivorView, isActive: true, contentSize: paneSize)

        #expect(window.firstResponder === survivorView)
    }

    @Test("window attach alone does not reclaim focus for the active pane")
    func windowAttachAloneDoesNotReclaimFocusForActivePane() throws {
        let fixture = try makeSplitFixture()
        let window = makeWindow()
        defer { window.close() }
        let runtime = GhosttyRuntime()
        defer { runtime.discardAllSurfaces() }
        let survivorView = makeSurvivorView(runtime: runtime, fixture: fixture)
        let parkingView = NSView(frame: NSRect(origin: .zero, size: paneSize))

        window.contentView?.addSubview(parkingView)
        window.makeFirstResponder(nil)
        parkingView.addSubview(survivorView)

        #expect(window.firstResponder !== survivorView)

        let container = mountContainer(in: window)
        container.mount(survivorView, isActive: true, contentSize: paneSize)

        #expect(window.firstResponder === survivorView)
    }

    @Test("a survivor orphaned by container churn nudges a SwiftUI remount")
    func orphanedSurvivorNudgesRemount() async throws {
        let fixture = try makeSplitFixture()
        let window = makeWindow()
        defer { window.close() }
        let runtime = GhosttyRuntime()
        defer { runtime.discardAllSurfaces() }
        let survivorView = makeSurvivorView(runtime: runtime, fixture: fixture)

        let survivingContainer = mountContainer(in: window)
        survivingContainer.mount(survivorView, isActive: true, contentSize: paneSize)
        // The doomed container (the stale split pass) steals the survivor,
        // then is dismantled — the observed INT-600 churn.
        let doomedContainer = mountContainer(in: window)
        doomedContainer.mount(survivorView, isActive: true, contentSize: paneSize)

        let revisionBefore = runtime.surfaceRemountNudgeRevision
        doomedContainer.removeFromSuperview()
        #expect(survivorView.window == nil)

        await drainMainQueue()

        #expect(runtime.surfaceRemountNudgeRevision > revisionBefore)
    }

    @Test("a discarded surface view does not nudge a remount when detached")
    func discardedSurfaceViewDoesNotNudgeRemount() async throws {
        let fixture = try makeSplitFixture()
        let window = makeWindow()
        defer { window.close() }
        let runtime = GhosttyRuntime()
        defer { runtime.discardAllSurfaces() }
        let survivorView = makeSurvivorView(runtime: runtime, fixture: fixture)

        let container = mountContainer(in: window)
        container.mount(survivorView, isActive: true, contentSize: paneSize)

        let revisionBefore = runtime.surfaceRemountNudgeRevision
        // A genuine close discards the cached view and detaches it — the
        // rescue must recognize the eviction and stay quiet.
        runtime.discardSurface(for: fixture.siblingPane.id)
        #expect(survivorView.window == nil)

        await drainMainQueue()

        #expect(runtime.surfaceRemountNudgeRevision == revisionBefore)
    }

    // MARK: - Fixture

    private let paneSize = CGSize(width: 640, height: 480)

    private func makeWindow() -> NSWindow {
        // Never ordered front: the window stays occlusion-invisible, so
        // mounting defers native surface creation (no shell spawns in tests)
        // while the responder chain and view hierarchy behave like the real
        // window's.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func mountContainer(in window: NSWindow) -> GhosttySurfaceContainerView {
        let container = GhosttySurfaceContainerView(contentSize: paneSize)
        container.frame = NSRect(origin: .zero, size: paneSize)
        window.contentView?.addSubview(container)
        return container
    }

    private func makeSurvivorView(
        runtime: GhosttyRuntime,
        fixture: SplitFixture
    ) -> GhosttySurfaceNSView {
        runtime.surfaceView(
            sessionStore: fixture.store,
            session: fixture.session,
            pane: fixture.siblingPane,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )
    }

    /// The orphan rescue defers its check one main-queue turn past the detach;
    /// enqueueing behind it and awaiting guarantees the check has run.
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func makeSplitFixture(deadPaneIsActive: Bool = false) throws -> SplitFixture {
        let deadPane = TerminalPane(
            title: "closing pane",
            workingDirectory: "/tmp/dead"
        )
        let siblingPane = TerminalPane(
            title: "survivor",
            workingDirectory: "/tmp/survivor"
        )
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(deadPane),
            second: .pane(siblingPane),
            firstFraction: 0.5
        ))
        let session = TerminalSession(
            title: "split",
            workingDirectory: "/tmp/dead",
            layout: layout,
            activePaneID: deadPaneIsActive ? deadPane.id : siblingPane.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "awesoMux", sessions: [session])],
            selectedSessionID: session.id
        )
        return SplitFixture(
            session: session,
            deadPane: deadPane,
            siblingPane: siblingPane,
            store: store
        )
    }

    private struct SplitFixture {
        let session: TerminalSession
        let deadPane: TerminalPane
        let siblingPane: TerminalPane
        let store: SessionStore
    }
}
