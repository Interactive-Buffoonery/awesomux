import Foundation
import Observation

@Observable
@MainActor
final class SidebarPresentationModel {
    private(set) var userWantsHidden: Bool
    private(set) var isTemporarilyRevealed = false

    var isSidebarVisible: Bool {
        !userWantsHidden || isTemporarilyRevealed
    }

    var permitsWidthChanges: Bool {
        !userWantsHidden
    }

    @ObservationIgnored private let store: SidebarPresentationPreferenceStore
    @ObservationIgnored private let delay: @Sendable (Duration) async -> Void
    @ObservationIgnored private var edgePointerPresent = false
    @ObservationIgnored private var sidebarPointerPresent = false
    @ObservationIgnored private var delayedHideTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(
        store: SidebarPresentationPreferenceStore = SidebarPresentationPreferenceStore(),
        delay: @Sendable @escaping (Duration) async -> Void = {
            try? await ContinuousClock().sleep(for: $0)
        }
    ) {
        self.store = store
        self.delay = delay
        userWantsHidden = store.isHidden()
    }

    func togglePersistentVisibility() {
        if userWantsHidden {
            showPersistently()
        } else {
            cancelDelayedHide()
            clearPointerPresence()
            userWantsHidden = true
            isTemporarilyRevealed = false
            store.saveHidden(true)
        }
    }

    func showPersistently() {
        cancelDelayedHide()
        clearPointerPresence()
        userWantsHidden = false
        isTemporarilyRevealed = false
        store.saveHidden(false)
    }

    func edgePointerChanged(_ isPresent: Bool) {
        guard userWantsHidden else { return }
        edgePointerPresent = isPresent
        pointerPresenceChanged(isPresent)
    }

    func sidebarPointerChanged(_ isPresent: Bool) {
        guard userWantsHidden else { return }
        sidebarPointerPresent = isPresent
        pointerPresenceChanged(isPresent)
    }

    func positionDidChange() {
        cancelDelayedHide()
        edgePointerPresent = false
        sidebarPointerPresent = false
        isTemporarilyRevealed = false
    }

    private func pointerPresenceChanged(_ isPresent: Bool) {
        if isPresent {
            cancelDelayedHide()
            isTemporarilyRevealed = true
        } else if !edgePointerPresent, !sidebarPointerPresent, isTemporarilyRevealed {
            scheduleDelayedHide()
        }
    }

    private func scheduleDelayedHide() {
        cancelDelayedHide()
        let scheduledGeneration = generation
        delayedHideTask = Task { @MainActor [weak self, delay] in
            await delay(.milliseconds(220))
            guard let self,
                !Task.isCancelled,
                self.generation == scheduledGeneration,
                !self.edgePointerPresent,
                !self.sidebarPointerPresent,
                self.userWantsHidden
            else {
                return
            }
            self.isTemporarilyRevealed = false
            self.delayedHideTask = nil
        }
    }

    private func cancelDelayedHide() {
        generation += 1
        delayedHideTask?.cancel()
        delayedHideTask = nil
    }

    private func clearPointerPresence() {
        edgePointerPresent = false
        sidebarPointerPresent = false
    }
}
