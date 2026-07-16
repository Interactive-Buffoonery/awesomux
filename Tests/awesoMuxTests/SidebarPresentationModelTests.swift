import Foundation
import AwesoMuxCore
import AwesoMuxTestSupport
import Observation
import Testing
@testable import awesoMux

@MainActor
@Suite("SidebarPresentationModel")
struct SidebarPresentationModelTests {
    @Test("one-third tracker classifies dormant cue and reveal boundaries")
    func attractionFieldBoundaries() throws {
        let (model, _, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        model.pointerMoved(x: 400, width: 400, position: .left)
        #expect(model.proximityState == .cue)

        model.pointerMoved(x: 399, width: 400, position: .left)
        #expect(model.proximityState == .cue)
        model.pointerMoved(x: 40, width: 400, position: .left)
        #expect(model.proximityState == .revealed)

        model.invalidateTransientState()
        model.pointerMoved(x: 0, width: 400, position: .right)
        #expect(model.proximityState == .cue)
        model.pointerMoved(x: 1, width: 400, position: .right)
        #expect(model.proximityState == .cue)
        model.pointerMoved(x: 360, width: 400, position: .right)
        #expect(model.proximityState == .revealed)
    }

    @Test("tracker exit is the dormant boundary")
    func trackerExitIsDormant() throws {
        let (model, _, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        model.pointerMoved(x: 400, width: 400, position: .left)
        model.trackingRegionExited()
        #expect(model.proximityState == .dormant)
    }

    @Test("invalid pointer samples fail dormant")
    func invalidPointerSamplesFailDormant() throws {
        for (x, width) in [
            (CGFloat.nan, 400),
            (200, CGFloat.nan),
            (200, CGFloat.infinity),
            (200, 0),
            (200, -1),
        ] {
            let (model, _, defaults, suiteName) = try makeHiddenModel()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            model.pointerMoved(x: 200, width: 400, position: .left)
            #expect(model.proximityState == .cue)

            model.pointerMoved(x: x, width: width, position: .left)

            #expect(model.proximityState == .dormant)
        }
    }

    @Test("leave grace restores tracker cue")
    func leaveGraceRestoresTrackerCue() async throws {
        let (model, gate, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        model.pointerMoved(x: 200, width: 400, position: .left)
        model.sidebarPointerChanged(true)
        model.sidebarPointerChanged(false)
        #expect(await waitUntil { gate.sleeperCount == 1 })

        gate.advance()
        #expect(await waitUntil { model.proximityState == .cue })
    }

    @Test("tracker motion then sidebar exit shares one leave grace")
    func trackerMotionThenSidebarExitSharesGrace() async throws {
        let (model, gate, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        model.pointerMoved(x: 60, width: 100, position: .left)
        model.pointerMoved(x: 15, width: 100, position: .left)
        model.sidebarPointerChanged(true)
        model.pointerMoved(x: 60, width: 100, position: .left)
        model.sidebarPointerChanged(false)

        #expect(model.proximityState == .revealed)
        #expect(await waitUntil { gate.sleeperCount == 1 })
        gate.advance()
        #expect(await waitUntil { model.proximityState == .cue })
    }

    @Test("sidebar exit then tracker motion shares one leave grace and latest cue")
    func sidebarExitThenTrackerMotionSharesGrace() async throws {
        let (model, gate, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        model.pointerMoved(x: 60, width: 100, position: .left)
        model.pointerMoved(x: 15, width: 100, position: .left)
        model.sidebarPointerChanged(true)
        model.sidebarPointerChanged(false)
        #expect(await waitUntil { gate.sleeperCount == 1 })
        model.pointerMoved(x: 60, width: 100, position: .left)

        #expect(model.proximityState == .revealed)
        #expect(gate.sleepCallCount == 1)
        gate.advance()
        #expect(await waitUntil { model.proximityState == .cue })
    }

    @Test("explicit persistent targets save intent and clear temporary reveal")
    func explicitPersistentTargetsSaveIntent() throws {
        let (model, _, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        model.pointerMoved(x: 15, width: 100, position: .left)
        #expect(model.applyPersistentHidden(false) { _ in .applied } == .applied)
        #expect(!model.userWantsHidden)
        #expect(model.permitsWidthChanges)
        #expect(!model.isTemporarilyRevealed)
        #expect(!SidebarPresentationPreferenceStore(defaults: defaults).isHidden())

        #expect(model.applyPersistentHidden(true) { _ in .applied } == .applied)
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
        #expect(model.applyPersistentHidden(false) { _ in .applied } == .applied)

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
        #expect(model.applyPersistentHidden(false) { _ in .applied } == .applied)
        model.sidebarPointerChanged(false)

        #expect(model.applyPersistentHidden(true) { _ in .applied } == .applied)
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

    @Test("completed grace blocked by interaction permits a fresh dismissal")
    func completedBlockedGraceReschedules() async throws {
        let (model, gate, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.pointerMoved(x: 15, width: 100, position: .left)
        model.trackingRegionExited()
        #expect(await waitUntil { gate.sleeperCount == 1 })

        model.sidebarInteractionChanged(true)
        gate.advanceOneCycle()
        await drainMainQueue()
        #expect(model.isTemporarilyRevealed)

        model.sidebarInteractionChanged(false)
        #expect(await waitUntil { gate.sleeperCount == 1 })
        #expect(gate.sleepCallCount == 2)
        gate.advance()
        #expect(await waitUntil { !model.isSidebarVisible })
    }

    @Test("rejected persistent transition leaves model and preference unchanged")
    func rejectedPersistentTransitionIsTransactional() throws {
        let (model, _, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.pointerMoved(x: 15, width: 100, position: .left)

        var requestedVisibility: Bool?
        #expect(
            model.applyPersistentHidden(false) { visible in
                requestedVisibility = visible
                return .rejected
            } == .rejected)

        #expect(requestedVisibility == true)
        #expect(model.userWantsHidden)
        #expect(model.isTemporarilyRevealed)
        #expect(SidebarPresentationPreferenceStore(defaults: defaults).isHidden())
        #expect(SidebarVisibilityActionTitle.resolve(isHidden: model.userWantsHidden) == "Show Sidebar")
    }

    @Test("an explicit target can retry after native rejection")
    func explicitTargetRetriesAfterRejection() throws {
        let (model, _, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var requestedVisibility: [Bool] = []
        #expect(
            model.applyPersistentHidden(false) { visible in
                requestedVisibility.append(visible)
                return .rejected
            } == .rejected)
        #expect(
            model.applyPersistentHidden(false) { visible in
                requestedVisibility.append(visible)
                return .applied
            } == .applied)

        #expect(requestedVisibility == [true, true])
        #expect(!model.userWantsHidden)
        #expect(!SidebarPresentationPreferenceStore(defaults: defaults).isHidden())
    }

    @Test("deferred persistent transition leaves model and preference unchanged")
    func deferredPersistentTransitionIsTransactional() throws {
        let (model, _, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.pointerMoved(x: 15, width: 100, position: .left)

        #expect(
            model.applyPersistentHidden(false) { _ in .deferredUntilHostReady }
                == .deferredUntilHostReady)

        #expect(model.userWantsHidden)
        #expect(model.isTemporarilyRevealed)
        #expect(SidebarPresentationPreferenceStore(defaults: defaults).isHidden())
    }

    @Test("repeated pointer classification does not republish the same state")
    func repeatedPointerStateIsNotRepublished() async throws {
        let (model, _, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.pointerMoved(x: 200, width: 400, position: .left)

        await confirmation(expectedCount: 0) { changed in
            withObservationTracking {
                _ = model.proximityState
            } onChange: {
                changed()
            }

            model.pointerMoved(x: 199, width: 400, position: .left)
        }

        #expect(model.proximityState == .cue)
    }

    @Test("pointer churn without a pending hide does not advance the transient generation")
    func pointerChurnWithoutPendingHideKeepsGenerationStable() throws {
        let (model, _, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initialGeneration = model.transientGenerationForTesting

        for _ in 0..<100 {
            model.pointerMoved(x: 15, width: 100, position: .left)
            model.sidebarPointerChanged(true)
        }

        #expect(model.proximityState == .revealed)
        #expect(model.transientGenerationForTesting == initialGeneration)
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
        model.pointerMoved(x: 50, width: 100, position: .left)
        model.sidebarPointerChanged(false)
        #expect(await waitUntil { gate.sleeperCount == 1 })
        model.pointerMoved(x: 50, width: 100, position: .left)
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
        for x in [50.0, 15.0] {
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

    @Test("rejected interaction-only reveal returns dormant without tracker presence")
    func rejectedInteractionRevealReturnsDormant() throws {
        let (model, _, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.sidebarInteractionChanged(true)
        #expect(model.proximityState == .revealed)

        model.transientPresentationRejected()

        #expect(model.proximityState == .dormant)
        #expect(!model.isSidebarVisible)
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
        model.pointerMoved(x: 50, width: 100, position: .left)
        #expect(model.proximityState == .cue)
        gate.advance()
        await drainMainQueue()

        #expect(model.proximityState == .cue)
        #expect(model.isCueVisible)
        #expect(!model.isSidebarVisible)
    }

    @Test("explicit invalidation from cue and reveal remains explicit")
    func explicitInvalidationSource() throws {
        for x in [50.0, 15.0] {
            let (model, _, defaults, suiteName) = try makeHiddenModel()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            model.pointerMoved(x: x, width: 100, position: .left)

            model.positionDidChange()

            #expect(model.proximityState == .dormant)
            #expect(model.visibilitySource == .explicit)
        }
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
