import AppKit
import AwesoMuxCore
import AwesoMuxTestSupport
import Testing
@testable import awesoMux

@MainActor
@Suite("Ghostty runtime surface GC")
struct GhosttyRuntimeSurfaceGCTests {
    @Test func queuedCommandIsCancelledBeforeMountAndDoesNotReachReopenedPane() async throws {
        let runtime = GhosttyRuntime()
        let clock = CommandRetryClock()
        runtime.commandRetryClock = clock
        defer { clock.finishAll() }
        defer { runtime.discardAllSurfaces() }
        let paneID = TerminalPane.ID()
        var submitted: [String] = []
        let closed = runtime.scheduleCommandRetry(toPane: paneID) { submitted.append("closed") }
        try #require(await waitUntil { clock.sleepers.count == 1 })
        runtime.discardSurface(for: paneID)
        let reopened = runtime.scheduleCommandRetry(toPane: paneID) { submitted.append("reopened") }
        try #require(await waitUntil { clock.sleepers.count == 2 })
        clock.resumeAll()
        await closed.value
        await reopened.value
        #expect(submitted == ["reopened"])
    }

    @Test func terminalInputCancelsQueuedCommand() async throws {
        let fixture = makeFixture()
        let runtime = GhosttyRuntime()
        let clock = CommandRetryClock()
        runtime.commandRetryClock = clock
        defer { clock.finishAll() }
        defer { runtime.discardAllSurfaces() }
        let view = runtime.surfaceView(
            sessionStore: fixture.store, session: fixture.session, pane: fixture.retainedPane,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )
        var submitted = 0
        let typing = runtime.scheduleCommandRetry(toPane: fixture.retainedPane.id) { submitted += 1 }
        try #require(await waitUntil { clock.sleepers.count == 1 })
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "x", charactersIgnoringModifiers: "x",
                isARepeat: false, keyCode: 7
            ))
        view.keyDown(with: event)
        clock.resumeAll()
        await typing.value
        let paste = runtime.scheduleCommandRetry(toPane: fixture.retainedPane.id) { submitted += 1 }
        try #require(await waitUntil { clock.sleepers.count == 1 })
        view.observeBindingAction("paste_from_clipboard", accepted: true, hasContent: true)
        clock.resumeAll()
        await paste.value
        #expect(submitted == 0)
    }

    @Test func releaseAndModifierEventsPreserveQueuedCommand() async throws {
        let fixture = makeFixture()
        let runtime = GhosttyRuntime()
        let clock = CommandRetryClock()
        runtime.commandRetryClock = clock
        defer { clock.finishAll(); runtime.discardAllSurfaces() }
        let view = runtime.surfaceView(
            sessionStore: fixture.store, session: fixture.session, pane: fixture.retainedPane,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )
        var submitted = 0
        let pending = runtime.scheduleCommandRetry(toPane: fixture.retainedPane.id) { submitted += 1 }
        try #require(await waitUntil { clock.sleepers.count == 1 })
        for type in [NSEvent.EventType.keyUp, .flagsChanged] {
            let event = try #require(
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: 36
                ))
            if type == .keyUp { view.keyUp(with: event) } else { view.flagsChanged(with: event) }
        }
        clock.resumeAll()
        await pending.value
        #expect(submitted == 1)
    }

    @Test func queuedCommandReplacementAndShutdownCancelOldActions() async throws {
        let runtime = GhosttyRuntime()
        let clock = CommandRetryClock()
        runtime.commandRetryClock = clock
        defer { clock.finishAll() }
        let paneID = TerminalPane.ID()
        var submitted: [String] = []
        let first = runtime.scheduleCommandRetry(toPane: paneID) { submitted.append("first") }
        try #require(await waitUntil { clock.sleepers.count == 1 })
        let second = runtime.scheduleCommandRetry(toPane: paneID) { submitted.append("second") }
        try #require(await waitUntil { clock.sleepers.count == 2 })
        clock.resumeAll()
        await first.value
        await second.value
        #expect(submitted == ["second"])
        let removedBeforeMount = runtime.scheduleCommandRetry(toPane: paneID) { submitted.append("removed") }
        try #require(await waitUntil { clock.sleepers.count == 1 })
        runtime.discardSurfacesNotIn([])
        clock.resumeAll()
        await removedBeforeMount.value
        #expect(submitted == ["second"])
        let shutdown = runtime.scheduleCommandRetry(toPane: paneID) { submitted.append("shutdown") }
        try #require(await waitUntil { clock.sleepers.count == 1 })
        runtime.discardAllSurfaces()
        clock.resumeAll()
        await shutdown.value
        #expect(submitted == ["second"])
    }

    @Test("sendText rejects a cached view before its native surface exists")
    func sendTextRejectsCachedViewWithoutNativeSurface() {
        let fixture = makeFixture()
        let runtime = GhosttyRuntime()
        defer { runtime.discardAllSurfaces() }
        let view = runtime.surfaceView(
            sessionStore: fixture.store,
            session: fixture.session,
            pane: fixture.retainedPane,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )
        #expect(runtime.cachedSurfaceView(for: fixture.retainedPane.id) === view)
        #expect(!view.hasNativeSurface)
        #expect(!runtime.sendText("printf ready\n", toPane: fixture.retainedPane.id))
        #expect(!runtime.sendText("printf ready\n", toPane: fixture.retainedPane.id, focusingSurface: false))
        view.shellCommandFinishedIdleLatched = true
        #expect(!runtime.submitCommand("printf ready", toPane: fixture.retainedPane.id))
        #expect(view.shellCommandFinishedIdleLatched)
    }

    @Test("visible surface registration starts and stops the runtime sampler")
    func visibleSurfaceRegistrationStartsAndStopsRuntimeSampler() {
        let fixture = makeFixture()
        let runtime = GhosttyRuntime()
        defer { runtime.discardAllSurfaces() }

        runtime.noteSurfaceVisibility(paneID: fixture.retainedPane.id, isVisible: true)

        #expect(runtime.visibleSurfaceSamplingPaneIDsForTesting == [fixture.retainedPane.id])
        #expect(runtime.hasVisibleSurfaceSamplingTaskForTesting)

        runtime.noteSurfaceVisibility(paneID: fixture.retainedPane.id, isVisible: false)

        #expect(runtime.visibleSurfaceSamplingPaneIDsForTesting.isEmpty)
        #expect(!runtime.hasVisibleSurfaceSamplingTaskForTesting)
    }

    @Test("discardSurface removes visible sampler membership")
    func discardSurfaceRemovesVisibleSamplerMembership() {
        let fixture = makeFixture()
        let runtime = GhosttyRuntime()
        defer { runtime.discardAllSurfaces() }
        _ = runtime.surfaceView(
            sessionStore: fixture.store,
            session: fixture.session,
            pane: fixture.retainedPane,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )
        runtime.noteSurfaceVisibility(paneID: fixture.retainedPane.id, isVisible: true)

        runtime.discardSurface(for: fixture.retainedPane.id)

        #expect(runtime.visibleSurfaceSamplingPaneIDsForTesting.isEmpty)
        #expect(!runtime.hasVisibleSurfaceSamplingTaskForTesting)
    }

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
    @MainActor
    private final class CommandRetryClock: Clock {
        nonisolated var now: ContinuousClock.Instant { ContinuousClock.now }
        nonisolated var minimumResolution: Duration { .nanoseconds(1) }
        var sleepers: [CheckedContinuation<Void, Never>] = []
        private var finished = false

        nonisolated func sleep(until _: ContinuousClock.Instant, tolerance _: Duration?) async throws {
            await wait()
        }

        private func wait() async {
            guard !finished else { return }
            await withCheckedContinuation { sleepers.append($0) }
        }

        func resumeAll() {
            let pending = sleepers
            sleepers.removeAll()
            pending.forEach { $0.resume() }
        }

        func finishAll() {
            finished = true
            resumeAll()
        }
    }

}
