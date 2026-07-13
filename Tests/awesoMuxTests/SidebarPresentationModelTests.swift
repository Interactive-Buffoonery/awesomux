import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("SidebarPresentationModel")
struct SidebarPresentationModelTests {
    @Test("hidden sidebar reveals at edge and stays visible during sidebar handoff")
    func edgeRevealHandsOffToSidebar() async throws {
        let (model, gate, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(model.userWantsHidden)
        #expect(!model.isSidebarVisible)
        model.edgePointerChanged(true)
        #expect(model.isTemporarilyRevealed)
        #expect(model.isSidebarVisible)
        model.edgePointerChanged(false)
        model.sidebarPointerChanged(true)
        gate.release()
        await drainMainQueue()
        #expect(model.isSidebarVisible)
    }

    @Test("persistent toggle saves hide intent and clears temporary reveal")
    func persistentToggleSavesIntent() throws {
        let (model, _, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        model.edgePointerChanged(true)
        model.togglePersistentVisibility()
        #expect(!model.userWantsHidden)
        #expect(!model.isTemporarilyRevealed)
        #expect(!SidebarPresentationPreferenceStore(defaults: defaults).isHidden())

        model.togglePersistentVisibility()
        #expect(model.userWantsHidden)
        #expect(!model.isSidebarVisible)
        #expect(SidebarPresentationPreferenceStore(defaults: defaults).isHidden())
    }

    @Test("explicit show makes the sidebar persistently visible")
    func explicitShowPersistsVisibility() throws {
        let (model, _, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        model.edgePointerChanged(true)
        model.showPersistently()

        #expect(!model.userWantsHidden)
        #expect(!model.isTemporarilyRevealed)
        #expect(model.isSidebarVisible)
        #expect(!SidebarPresentationPreferenceStore(defaults: defaults).isHidden())
    }

    @Test("leaving both hover regions hides after the grace")
    func leavingBothRegionsHidesAfterGrace() async throws {
        let (model, gate, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.edgePointerChanged(true)
        model.edgePointerChanged(false)
        #expect(await waitUntil { gate.waiterCount == 1 })

        gate.release()
        #expect(await waitUntil { !model.isTemporarilyRevealed })
        #expect(!model.isSidebarVisible)
    }

    @Test("re-entering either region cancels pending hide")
    func reentryCancelsPendingHide() async throws {
        let (model, gate, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.edgePointerChanged(true)
        model.edgePointerChanged(false)
        #expect(await waitUntil { gate.waiterCount == 1 })

        model.edgePointerChanged(true)
        gate.release()
        await drainMainQueue()
        #expect(model.isTemporarilyRevealed)
    }

    @Test("stale delay cannot hide a newer reveal")
    func staleDelayCannotHideNewReveal() async throws {
        let (model, gate, defaults, suiteName) = try makeHiddenModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.edgePointerChanged(true)
        model.edgePointerChanged(false)
        #expect(await waitUntil { gate.waiterCount == 1 })
        model.edgePointerChanged(true)
        model.sidebarPointerChanged(true)
        model.edgePointerChanged(false)

        gate.release()
        await drainMainQueue()
        #expect(model.isSidebarVisible)
        #expect(model.isTemporarilyRevealed)
    }

    @Test("hover events do nothing while persistently visible")
    func hoverEventsDoNothingWhenPersistentlyVisible() async throws {
        let (model, gate, defaults, suiteName) = try makeVisibleModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        model.edgePointerChanged(true)
        model.edgePointerChanged(false)
        model.sidebarPointerChanged(true)
        model.sidebarPointerChanged(false)
        await drainMainQueue()

        #expect(model.isSidebarVisible)
        #expect(!model.isTemporarilyRevealed)
        #expect(gate.waitCallCount == 0)
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
        let gate = ManualDelayGate()
        let model = SidebarPresentationModel(store: store, sleep: { _ in await gate.wait() })
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
    gate: ManualDelayGate,
    defaults: UserDefaults,
    suiteName: String
)
