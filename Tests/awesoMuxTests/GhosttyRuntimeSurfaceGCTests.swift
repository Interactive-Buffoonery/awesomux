import AwesoMuxCore
import Testing
@testable import awesoMux

@MainActor
@Suite("Ghostty runtime surface GC")
struct GhosttyRuntimeSurfaceGCTests {
    @Test("discardSurfacesNotIn preserves retained cached surfaces")
    func discardSurfacesNotInPreservesRetainedCachedSurfaces() {
        let fixture = makeFixture()
        let runtime = GhosttyRuntime()
        defer { runtime.discardAllSurfaces() }
        let retainedView = runtime.surfaceView(
            sessionStore: fixture.store,
            session: fixture.session,
            pane: fixture.retainedPane,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )
        _ = runtime.surfaceView(
            sessionStore: fixture.store,
            session: fixture.session,
            pane: fixture.stalePane,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )
        let revisionBefore = runtime.surfaceCacheRevision

        runtime.discardSurfacesNotIn([fixture.retainedPane.id])

        #expect(runtime.cachedSurfaceView(for: fixture.retainedPane.id) === retainedView)
        #expect(runtime.cachedSurfaceView(for: fixture.stalePane.id) == nil)
        #expect(runtime.surfaceCacheRevision == revisionBefore + 1)
    }

    @Test("discardSurfacesNotIn is a no-op when every cached surface is retained")
    func discardSurfacesNotInNoOpsWhenEveryCachedSurfaceIsRetained() {
        let fixture = makeFixture()
        let runtime = GhosttyRuntime()
        defer { runtime.discardAllSurfaces() }
        let firstView = runtime.surfaceView(
            sessionStore: fixture.store,
            session: fixture.session,
            pane: fixture.retainedPane,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )
        let secondView = runtime.surfaceView(
            sessionStore: fixture.store,
            session: fixture.session,
            pane: fixture.stalePane,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )
        let revisionBefore = runtime.surfaceCacheRevision

        runtime.discardSurfacesNotIn([fixture.retainedPane.id, fixture.stalePane.id])

        #expect(runtime.cachedSurfaceView(for: fixture.retainedPane.id) === firstView)
        #expect(runtime.cachedSurfaceView(for: fixture.stalePane.id) === secondView)
        #expect(runtime.surfaceCacheRevision == revisionBefore)
    }

    private func makeFixture() -> Fixture {
        let retainedPane = TerminalPane(title: "retained", workingDirectory: "/tmp/retained", executionPlan: .local)
        let stalePane = TerminalPane(title: "stale", workingDirectory: "/tmp/stale", executionPlan: .local)
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(retainedPane),
            second: .pane(stalePane)
        ))
        let session = TerminalSession(
            title: "gc",
            workingDirectory: "/tmp/retained",
            layout: layout,
            activePaneID: retainedPane.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "awesoMux", sessions: [session])],
            selectedSessionID: session.id
        )
        return Fixture(
            retainedPane: retainedPane,
            stalePane: stalePane,
            session: session,
            store: store
        )
    }

    private struct Fixture {
        let retainedPane: TerminalPane
        let stalePane: TerminalPane
        let session: TerminalSession
        let store: SessionStore
    }
}
