import AwesoMuxConfig
import Foundation
import Observation

@Observable
@MainActor
final class SidebarPresentationModel {
    enum ProximityState: Equatable {
        case dormant
        case cue
        case revealed
    }

    static let cueDistance: CGFloat = 80
    static let revealDistance: CGFloat = 16
    static let leaveGrace: Duration = .milliseconds(220)

    private(set) var userWantsHidden: Bool
    private(set) var proximityState: ProximityState = .dormant
    @ObservationIgnored private(set) var visibilitySource: SidebarVisibilitySource = .explicit

    var isTemporarilyRevealed: Bool {
        proximityState == .revealed
    }

    var isCueVisible: Bool {
        userWantsHidden && proximityState == .cue
    }

    var isSidebarVisible: Bool {
        !userWantsHidden || proximityState == .revealed
    }

    var permitsWidthChanges: Bool {
        !userWantsHidden
    }

    @ObservationIgnored private let store: SidebarPresentationPreferenceStore
    @ObservationIgnored private let delay: @Sendable (Duration) async -> Void
    @ObservationIgnored private var trackerState: ProximityState = .dormant
    @ObservationIgnored private var sidebarPointerPresent = false
    @ObservationIgnored private var sidebarInteractionActive = false
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
            clearTransientState()
            userWantsHidden = true
            store.saveHidden(true)
        }
    }

    func showPersistently() {
        clearTransientState()
        userWantsHidden = false
        store.saveHidden(false)
    }

    func pointerMoved(x: CGFloat, width: CGFloat, position: AppearanceConfig.SidebarPosition) {
        guard userWantsHidden, width.isFinite, width > 0, x.isFinite else { return }

        let clampedX = min(max(0, x), width)
        let distance = position == .left ? clampedX : width - clampedX
        let next: ProximityState
        if distance < Self.revealDistance {
            next = .revealed
        } else if distance <= Self.cueDistance {
            next = .cue
        } else {
            next = .dormant
        }
        trackerState = next

        if sidebarPointerPresent {
            transition(to: .revealed)
            return
        }
        transition(to: next)
    }

    func trackingRegionExited() {
        guard userWantsHidden else { return }
        trackerState = .dormant
        if sidebarInteractionActive {
            transition(to: .revealed)
            return
        }
        if proximityState == .revealed {
            scheduleDelayedTransition(to: .dormant)
        } else {
            transition(to: .dormant)
        }
    }

    // Kept until the tracking view switches to coordinate-based pointer updates.
    func edgePointerChanged(_ isPresent: Bool) {
        guard userWantsHidden else { return }
        if isPresent {
            trackerState = .revealed
            transition(to: .revealed)
        } else {
            trackingRegionExited()
        }
    }

    func sidebarPointerChanged(_ isPresent: Bool) {
        guard userWantsHidden else { return }
        sidebarPointerPresent = isPresent
        if isPresent {
            transition(to: .revealed)
        } else if sidebarInteractionActive {
            transition(to: .revealed)
        } else if trackerState == .revealed {
            transition(to: .revealed)
        } else if proximityState == .revealed {
            scheduleDelayedTransition(to: trackerState)
        }
    }

    func sidebarInteractionChanged(_ active: Bool) {
        guard userWantsHidden else { return }
        sidebarInteractionActive = active
        if active {
            transition(to: .revealed)
        } else if !sidebarPointerPresent, trackerState != .revealed {
            scheduleDelayedTransition(to: trackerState)
        }
    }

    func positionDidChange() {
        clearTransientState()
    }

    func invalidateTransientState() {
        clearTransientState()
    }

    var transientGenerationForTesting: Int { generation }

    private func transition(to next: ProximityState) {
        cancelDelayedHide()
        visibilitySource = .pointer
        proximityState = next
    }

    private func scheduleDelayedTransition(to next: ProximityState) {
        cancelDelayedHide()
        let scheduledGeneration = generation
        delayedHideTask = Task { @MainActor [weak self, delay] in
            await delay(Self.leaveGrace)
            guard let self,
                !Task.isCancelled,
                self.generation == scheduledGeneration,
                !self.sidebarPointerPresent,
                !self.sidebarInteractionActive,
                self.userWantsHidden
            else {
                return
            }
            self.visibilitySource = .pointer
            self.proximityState = next
            self.delayedHideTask = nil
        }
    }

    private func cancelDelayedHide() {
        generation += 1
        delayedHideTask?.cancel()
        delayedHideTask = nil
    }

    private func clearTransientState() {
        cancelDelayedHide()
        trackerState = .dormant
        sidebarPointerPresent = false
        sidebarInteractionActive = false
        visibilitySource = .explicit
        proximityState = .dormant
    }
}

enum SidebarAttentionCuePolicy {
    static func hasAttention(needsAcknowledgement: Bool, unreadNotificationCount: Int) -> Bool {
        needsAcknowledgement || unreadNotificationCount > 0
    }

    static func shouldGlow(isPersistentlyHidden: Bool, hasAttention: Bool) -> Bool {
        isPersistentlyHidden && hasAttention
    }
}

enum SidebarVisibilityActionTitle {
    static func resolve(isHidden: Bool) -> String {
        isHidden ? "Show Sidebar" : "Hide Sidebar"
    }
}
