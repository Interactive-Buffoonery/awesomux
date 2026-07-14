import Foundation
import AwesoMuxCore
import AwesoMuxTestSupport
import Testing
@testable import awesoMux

@MainActor
@Suite("SidebarPresentationModel")
struct SidebarPresentationModelTests {
    @Test("80 points cues and inside 16 points reveals on both sides")
    func exactProximityBoundaries() throws {
        let (model, _, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        model.pointerMoved(x: 20, width: 100, position: .right)
        #expect(model.proximityState == .cue)
        #expect(model.isCueVisible)
        #expect(!model.isSidebarVisible)

        model.pointerMoved(x: 84, width: 100, position: .right)
        #expect(model.proximityState == .cue)
        model.pointerMoved(x: 84.5, width: 100, position: .right)
        #expect(model.proximityState == .revealed)

        model.invalidateTransientState()
        model.pointerMoved(x: 80, width: 100, position: .left)
        #expect(model.proximityState == .cue)
        model.pointerMoved(x: 15.5, width: 100, position: .left)
        #expect(model.proximityState == .revealed)
    }

    @Test("distance outside 80 points is dormant")
    func outsideCueZoneIsDormant() throws {
        let (model, _, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        model.pointerMoved(x: 80.5, width: 100, position: .left)
        #expect(model.proximityState == .dormant)
    }

    @Test("threshold jitter always classifies into one stable state")
    func thresholdJitterIsDeterministic() throws {
        let (model, _, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for (x, expected) in [(80.0, .cue), (79.9, .cue), (16.0, .cue), (15.9, .revealed)]
            as [(CGFloat, SidebarPresentationModel.ProximityState)]
        {
            model.pointerMoved(x: x, width: 100, position: .left)
            #expect(model.proximityState == expected)
        }
    }

    @Test("persistent toggle saves hide intent and clears temporary reveal")
    func persistentToggleSavesIntent() throws {
        let (model, _, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        model.pointerMoved(x: 15, width: 100, position: .left)
        model.togglePersistentVisibility()
        #expect(!model.userWantsHidden)
        #expect(model.permitsWidthChanges)
        #expect(!model.isTemporarilyRevealed)
        #expect(!SidebarPresentationPreferenceStore(defaults: defaults).isHidden())

        model.togglePersistentVisibility()
        #expect(model.userWantsHidden)
        #expect(!model.permitsWidthChanges)
        #expect(!model.isSidebarVisible)
        #expect(SidebarPresentationPreferenceStore(defaults: defaults).isHidden())
    }

    @Test("explicit show makes the sidebar persistently visible")
    func explicitShowPersistsVisibility() throws {
        let (model, _, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        model.pointerMoved(x: 15, width: 100, position: .left)
        model.showPersistently()

        #expect(!model.userWantsHidden)
        #expect(!model.isTemporarilyRevealed)
        #expect(model.isSidebarVisible)
        #expect(!SidebarPresentationPreferenceStore(defaults: defaults).isHidden())
    }

    @Test("explicit visibility changes clear stale hover presence")
    func explicitVisibilityChangesClearStaleHoverPresence() async throws {
        let (model, gate, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        model.pointerMoved(x: 15, width: 100, position: .left)
        model.sidebarPointerChanged(true)
        model.showPersistently()
        model.sidebarPointerChanged(false)

        model.togglePersistentVisibility()
        model.pointerMoved(x: 15, width: 100, position: .left)
        model.trackingRegionExited()
        #expect(await waitUntil { gate.sleeperCount == 1 })

        gate.advance()
        #expect(await waitUntil { !model.isSidebarVisible })
    }

    @Test("leaving both hover regions hides after the grace")
    func leavingBothRegionsHidesAfterGrace() async throws {
        let (model, gate, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.pointerMoved(x: 15, width: 100, position: .left)
        model.trackingRegionExited()
        #expect(await waitUntil { gate.sleeperCount == 1 })

        gate.advance()
        #expect(await waitUntil { !model.isTemporarilyRevealed })
        #expect(!model.isSidebarVisible)
    }

    @Test("active sidebar interaction cancels leave grace and retains reveal")
    func interactionRetainsReveal() async throws {
        let (model, gate, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.pointerMoved(x: 15, width: 100, position: .left)
        model.trackingRegionExited()
        #expect(await waitUntil { gate.sleeperCount == 1 })

        model.sidebarInteractionChanged(true)
        gate.advance()
        await drainMainQueue()

        #expect(model.isTemporarilyRevealed)
    }

    @Test("clearing sidebar interaction starts a fresh leave grace")
    func clearingInteractionStartsFreshGrace() async throws {
        let (model, gate, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.pointerMoved(x: 15, width: 100, position: .left)
        model.sidebarInteractionChanged(true)
        model.trackingRegionExited()

        model.sidebarInteractionChanged(false)
        #expect(await waitUntil { gate.sleeperCount == 1 })
        gate.advance()
        #expect(await waitUntil { !model.isSidebarVisible })
    }

    @Test("re-entering either region cancels pending hide")
    func reentryCancelsPendingHide() async throws {
        let (model, gate, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.pointerMoved(x: 15, width: 100, position: .left)
        model.trackingRegionExited()
        #expect(await waitUntil { gate.sleeperCount == 1 })

        model.pointerMoved(x: 15, width: 100, position: .left)
        gate.advance()
        await drainMainQueue()
        #expect(model.isTemporarilyRevealed)
    }

    @Test("stale delay cannot hide a newer reveal")
    func staleDelayCannotHideNewReveal() async throws {
        let (model, gate, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.pointerMoved(x: 15, width: 100, position: .left)
        model.trackingRegionExited()
        #expect(await waitUntil { gate.sleeperCount == 1 })
        model.pointerMoved(x: 15, width: 100, position: .left)
        model.sidebarPointerChanged(true)
        model.trackingRegionExited()

        gate.advance()
        await drainMainQueue()
        #expect(model.isSidebarVisible)
        #expect(model.isTemporarilyRevealed)
    }

    @Test("hover events do nothing while persistently visible")
    func hoverEventsDoNothingWhenPersistentlyVisible() async throws {
        let (model, gate, defaults, suiteName) = try makeVisibleModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        model.pointerMoved(x: 15, width: 100, position: .left)
        model.trackingRegionExited()
        model.sidebarPointerChanged(true)
        model.sidebarPointerChanged(false)
        await drainMainQueue()

        #expect(model.isSidebarVisible)
        #expect(!model.isTemporarilyRevealed)
        #expect(gate.sleepCallCount == 0)
    }

    @Test("sidebar handoff cancels grace and remains authoritative")
    func sidebarHandoffCancelsGrace() async throws {
        let (model, gate, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        model.pointerMoved(x: 15, width: 100, position: .left)
        model.trackingRegionExited()
        #expect(await waitUntil { gate.sleeperCount == 1 })
        model.sidebarPointerChanged(true)
        gate.advance()
        await drainMainQueue()
        #expect(model.proximityState == .revealed)

        model.pointerMoved(x: 30, width: 100, position: .left)
        #expect(model.proximityState == .revealed)
    }

    @Test("newer cue transition survives stale grace completion")
    func newerCueSurvivesStaleGrace() async throws {
        let (model, gate, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        model.pointerMoved(x: 15, width: 100, position: .left)
        model.sidebarPointerChanged(true)
        model.pointerMoved(x: 30, width: 100, position: .left)
        model.sidebarPointerChanged(false)
        #expect(await waitUntil { gate.sleeperCount == 1 })
        model.pointerMoved(x: 30, width: 100, position: .left)
        gate.advance()
        await drainMainQueue()
        #expect(model.proximityState == .cue)
    }

    @Test("sidebar overlap event order cannot downgrade reveal")
    func sidebarOverlapOrderIsStable() throws {
        let (model, _, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        model.pointerMoved(x: 15, width: 40, position: .left)
        model.sidebarPointerChanged(true)
        model.pointerMoved(x: 30, width: 40, position: .left)
        #expect(model.proximityState == .revealed)

        model.invalidateTransientState()
        model.sidebarPointerChanged(true)
        model.pointerMoved(x: 30, width: 40, position: .left)
        #expect(model.proximityState == .revealed)
    }

    @Test("lifecycle invalidation cancels delayed collapse")
    func lifecycleInvalidationCancelsGrace() async throws {
        let (model, gate, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        model.pointerMoved(x: 15, width: 100, position: .left)
        model.trackingRegionExited()
        #expect(await waitUntil { gate.sleeperCount == 1 })
        model.invalidateTransientState()
        gate.advance()
        await drainMainQueue()
        #expect(model.proximityState == .dormant)
    }

    @Test("availability loss from cue and reveal is explicit")
    func availabilityLossIsExplicit() throws {
        for x in [30.0, 15.0] {
            let (model, _, defaults, suiteName) = try makeHiddenModel()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            model.pointerMoved(x: x, width: 100, position: .left)
            #expect(model.visibilitySource == .pointer)

            model.invalidateTransientState()

            #expect(model.proximityState == .dormant)
            #expect(model.visibilitySource == .explicit)
        }
    }

    @Test("inactive or detached invalidation clears cue and reveal immediately")
    func availabilityInvalidationClearsTransientPresentation() throws {
        for x in [20.0, 15.0] {
            let (model, _, defaults, suiteName) = try makeHiddenModel()
            defer { defaults.removePersistentDomain(forName: suiteName) }

            model.pointerMoved(x: x, width: 40, position: .left)
            model.invalidateTransientState()

            #expect(model.proximityState == .dormant)
            #expect(!model.isCueVisible)
            #expect(!model.isSidebarVisible)
        }
    }

    @Test("position change invalidates a pending leave grace")
    func positionChangeInvalidatesPendingGrace() async throws {
        let (model, gate, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        model.pointerMoved(x: 15, width: 100, position: .left)
        model.trackingRegionExited()
        #expect(await waitUntil { gate.sleeperCount == 1 })
        let scheduledGeneration = model.transientGenerationForTesting

        model.positionDidChange()
        #expect(model.transientGenerationForTesting > scheduledGeneration)
        model.pointerMoved(x: 30, width: 100, position: .left)
        #expect(model.proximityState == .cue)
        gate.advance()
        await drainMainQueue()

        #expect(model.proximityState == .cue)
        #expect(model.isCueVisible)
        #expect(!model.isSidebarVisible)
    }

    @Test("explicit invalidation from cue and reveal remains explicit")
    func explicitInvalidationSource() throws {
        for x in [30.0, 15.0] {
            let (model, _, defaults, suiteName) = try makeHiddenModel()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            model.pointerMoved(x: x, width: 100, position: .left)

            model.positionDidChange()

            #expect(model.proximityState == .dormant)
            #expect(model.visibilitySource == .explicit)
        }
    }

    @Test("hidden width selection leaves presentation dormant and hidden")
    func hiddenWidthSelectionPreservesPresentation() throws {
        let (model, _, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let result = SidebarHiddenWidthTogglePolicy.resolve(
            currentWidth: 300,
            lastNonCollapsedWidth: 300,
            persistentlyHidden: model.userWantsHidden
        )

        #expect(result.targetWidth == SidebarWidthPolicy.collapsedWidth)
        #expect(!result.shouldReveal)
        #expect(model.proximityState == .dormant)
        #expect(model.userWantsHidden)
    }

    private func makeHiddenModel() throws -> ModelFixture {
        try makeModel(hidden: true)
    }

    private func makeVisibleModel() throws -> ModelFixture {
        try makeModel(hidden: false)
    }

    private func makeModel(hidden: Bool) throws -> ModelFixture {
        let suiteName = "SidebarPresentationModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SidebarPresentationPreferenceStore(defaults: defaults)
        store.saveHidden(hidden)
        let gate = TestScheduler()
        let model = SidebarPresentationModel(store: store, delay: { await gate.wait(for: $0) })
        return (model, gate, defaults, suiteName)
    }

    private func waitUntil(
        _ condition: () -> Bool,
        attempts: Int = 10_000
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

private typealias ModelFixture = (
    model: SidebarPresentationModel,
    gate: TestScheduler,
    defaults: UserDefaults,
    suiteName: String
)
