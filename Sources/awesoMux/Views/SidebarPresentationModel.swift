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

    /// The three sensors that can hold the sidebar revealed once it is up:
    /// pointer over the sidebar body, pointer over a peek card, or an active
    /// keyboard/AX interaction. They fan into one occupancy latch.
    private enum RevealedSurface {
        case sidebarBody
        case peekCard
        case interaction
    }

    @ObservationIgnored private let store: SidebarPresentationPreferenceStore
    @ObservationIgnored private let delay: @Sendable (Duration) async -> Void
    // Authority 1: edge distance. Authority 2: revealed-surface occupancy.
    @ObservationIgnored private var trackerState: ProximityState = .dormant
    @ObservationIgnored private var occupancy: Set<RevealedSurface> = []
    @ObservationIgnored private var delayedHideTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// Any sensor keeping the revealed sidebar up.
    private var isRevealHeld: Bool { !occupancy.isEmpty }
    /// Pointer-over presence only (excludes keyboard/AX). Rejection fallback
    /// uses this: an interaction-only reveal that the host rejects has no
    /// pointer anchor, so it collapses to dormant rather than cue.
    private var pointerOverPresent: Bool {
        occupancy.contains(.sidebarBody) || occupancy.contains(.peekCard)
    }

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

    // MARK: - Authority 1: edge distance

    func pointerMoved(x: CGFloat, width: CGFloat, position: AppearanceConfig.SidebarPosition) {
        guard userWantsHidden else { return }
        guard width.isFinite, width > 0, x.isFinite else {
            trackerState = .dormant
            transition(to: .dormant)
            return
        }

        let clampedX = min(max(0, x), width)
        let distance = position == .left ? clampedX : width - clampedX
        let next: ProximityState = distance <= Self.revealDistance ? .revealed : .cue
        trackerState = next

        if isRevealHeld {
            transition(to: .revealed)
            return
        }
        transitionRespectingLeaveGrace(to: next)
    }

    func trackingRegionExited() {
        guard userWantsHidden else { return }
        trackerState = .dormant
        if isRevealHeld {
            transition(to: .revealed)
            return
        }
        transitionRespectingLeaveGrace(to: .dormant)
    }

    // MARK: - Authority 2: revealed-surface occupancy

    func sidebarPointerChanged(_ isPresent: Bool) {
        setOccupancy(.sidebarBody, present: isPresent)
    }

    func peekPointerChanged(_ isPresent: Bool) {
        setOccupancy(.peekCard, present: isPresent)
    }

    func sidebarInteractionChanged(_ active: Bool) {
        setOccupancy(.interaction, present: active)
    }

    /// Single occupancy latch shared by every revealed-surface sensor. While
    /// any sensor is present the sidebar stays revealed; when the last one
    /// leaves we fall back to the edge tracker through the leave grace.
    private func setOccupancy(_ surface: RevealedSurface, present: Bool) {
        guard userWantsHidden else { return }
        if present {
            occupancy.insert(surface)
            transition(to: .revealed)
            return
        }
        // A redundant release (the surface was never held) must not run the
        // fallback — doing so would stomp visibility ownership set elsewhere.
        guard occupancy.remove(surface) != nil else { return }
        if isRevealHeld {
            transition(to: .revealed)
        } else if proximityState == .revealed {
            scheduleDelayedTrackerTransition()
        } else {
            transition(to: trackerState)
        }
    }

    func positionDidChange() {
        cancelDelayedHide()
        trackerState = .dormant
        occupancy.remove(.sidebarBody)
        occupancy.remove(.peekCard)
        visibilitySource = .explicit
        proximityState = isRevealHeld ? .revealed : .dormant
    }

    func invalidateTransientState() {
        clearTransientState()
    }

    func transientPresentationRejected() {
        guard userWantsHidden, proximityState == .revealed else { return }
        cancelDelayedHide()
        visibilitySource = .pointer
        proximityState =
            trackerState == .dormant && !pointerOverPresent
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
            guard self.occupancy.isEmpty, self.userWantsHidden else {
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
        occupancy.removeAll()
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
