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

    static let revealDistance: CGFloat = 40
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
    @ObservationIgnored private var peekPointerPresent = false
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

    @discardableResult
    func applyPersistentHidden(
        _ hidden: Bool,
        applyNativeVisibility: (Bool) -> SidebarPersistentVisibilityDeliveryResult
    ) -> SidebarPersistentVisibilityDeliveryResult {
        let deliveryResult = applyNativeVisibility(!hidden)
        guard deliveryResult == .applied else { return deliveryResult }
        clearTransientState()
        userWantsHidden = hidden
        store.saveHidden(hidden)
        return .applied
    }

    func pointerMoved(x: CGFloat, width: CGFloat, position: AppearanceConfig.SidebarPosition) {
        guard userWantsHidden else { return }
        guard width.isFinite, width > 0, x.isFinite else {
            trackerState = .dormant
            transition(to: .dormant)
            return
        }

        let clampedX = min(max(0, x), width)
        let distance = position == .left ? clampedX : width - clampedX
        let next: ProximityState
        if distance <= Self.revealDistance {
            next = .revealed
        } else {
            next = .cue
        }
        trackerState = next

        if sidebarPointerPresent || peekPointerPresent {
            transition(to: .revealed)
            return
        }
        transitionRespectingLeaveGrace(to: next)
    }

    func trackingRegionExited() {
        guard userWantsHidden else { return }
        trackerState = .dormant
        if sidebarInteractionActive || peekPointerPresent {
            transition(to: .revealed)
            return
        }
        transitionRespectingLeaveGrace(to: .dormant)
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
        } else if sidebarInteractionActive || peekPointerPresent {
            transition(to: .revealed)
        } else if proximityState == .revealed {
            scheduleDelayedTrackerTransition()
        } else {
            transitionRespectingLeaveGrace(to: trackerState)
        }
    }

    func peekPointerChanged(_ isPresent: Bool) {
        guard userWantsHidden else { return }
        guard isPresent != peekPointerPresent else { return }
        peekPointerPresent = isPresent
        if isPresent {
            transition(to: .revealed)
        } else if sidebarPointerPresent || sidebarInteractionActive {
            transition(to: .revealed)
        } else if proximityState == .revealed {
            scheduleDelayedTrackerTransition()
        } else {
            transitionRespectingLeaveGrace(to: trackerState)
        }
    }

    func sidebarInteractionChanged(_ active: Bool) {
        guard userWantsHidden else { return }
        sidebarInteractionActive = active
        if active {
            transition(to: .revealed)
        } else if !sidebarPointerPresent, !peekPointerPresent, trackerState != .revealed {
            transitionRespectingLeaveGrace(to: trackerState)
        }
    }

    func positionDidChange() {
        cancelDelayedHide()
        trackerState = .dormant
        sidebarPointerPresent = false
        peekPointerPresent = false
        visibilitySource = .explicit
        proximityState = sidebarInteractionActive ? .revealed : .dormant
    }

    func invalidateTransientState() {
        clearTransientState()
    }

    func transientPresentationRejected() {
        guard userWantsHidden, proximityState == .revealed else { return }
        cancelDelayedHide()
        visibilitySource = .pointer
        proximityState =
            trackerState == .dormant && !sidebarPointerPresent && !peekPointerPresent
            ? .dormant
            : .cue
    }

    var transientGenerationForTesting: Int { generation }

    private func transition(to next: ProximityState) {
        cancelDelayedHide()
        visibilitySource = .pointer
        publish(next)
    }

    private func transitionRespectingLeaveGrace(to next: ProximityState) {
        guard proximityState == .revealed, next != .revealed else {
            transition(to: next)
            return
        }
        scheduleDelayedTrackerTransition()
    }

    private func scheduleDelayedTrackerTransition() {
        guard delayedHideTask == nil else { return }
        let scheduledGeneration = generation
        delayedHideTask = Task { @MainActor [weak self, delay] in
            await delay(Self.leaveGrace)
            guard let self,
                !Task.isCancelled,
                self.generation == scheduledGeneration
            else {
                return
            }
            self.delayedHideTask = nil
            guard
                !self.sidebarPointerPresent,
                !self.peekPointerPresent,
                !self.sidebarInteractionActive,
                self.userWantsHidden
            else {
                return
            }
            self.visibilitySource = .pointer
            self.publish(self.trackerState)
        }
    }

    private func cancelDelayedHide() {
        guard delayedHideTask != nil else { return }
        generation += 1
        delayedHideTask?.cancel()
        delayedHideTask = nil
    }

    private func clearTransientState() {
        cancelDelayedHide()
        trackerState = .dormant
        sidebarPointerPresent = false
        peekPointerPresent = false
        sidebarInteractionActive = false
        visibilitySource = .explicit
        proximityState = .dormant
    }

    private func publish(_ next: ProximityState) {
        guard proximityState != next else { return }
        proximityState = next
    }
}

enum SidebarEdgeTabPolicy {
    enum Style: Equatable {
        case cue
        case attention
    }

    static func resolve(
        isPersistentlyHidden: Bool,
        proximity: SidebarPresentationModel.ProximityState,
        hasAttention: Bool,
        isControlActive: Bool = true
    ) -> Style? {
        guard isControlActive, isPersistentlyHidden else { return nil }
        switch proximity {
        case .cue:
            return .cue
        case .revealed:
            return nil
        case .dormant:
            return hasAttention ? .attention : nil
        }
    }

    static func hasAttention(
        needsAcknowledgement: Bool,
        unreadNotificationCount: Int
    ) -> Bool {
        needsAcknowledgement || unreadNotificationCount > 0
    }

    static func shouldScanAttention(
        isPersistentlyHidden: Bool,
        proximity: SidebarPresentationModel.ProximityState,
        isControlActive: Bool = true
    ) -> Bool {
        isControlActive && isPersistentlyHidden && proximity == .dormant
    }

}

enum SidebarVisibilityActionTitle {
    static func resolve(isHidden: Bool) -> String {
        if isHidden {
            return String(
                localized: "Show Sidebar",
                comment: "Menu and command palette action that makes the sidebar persistently visible."
            )
        }
        return String(
            localized: "Hide Sidebar",
            comment: "Menu and command palette action that hides the sidebar persistently."
        )
    }
}
