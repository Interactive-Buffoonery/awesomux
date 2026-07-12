enum GhosttyMouseButtonPolicyDecision: Equatable {
    case send
    case suppress
}

/// Pure mouse-button press/release pairing for `GhosttySurfaceNSView`.
///
/// AppKit can deliver a release after the native libghostty surface that saw
/// the press has gone away and a command-bridge heal has created a new one.
/// The bridge passes a caller-owned surface identity into this policy so the
/// paired release only reaches the same surface incarnation that accepted the
/// press.
struct GhosttySurfaceMouseButtonPolicy<SurfaceIdentity: Equatable> {
    enum Button: Hashable {
        case left
        case right
        case other
    }

    private enum PendingRelease {
        case sent(to: SurfaceIdentity)
        case suppressed
    }

    private var pendingReleases: [Button: PendingRelease] = [:]
    private var focusOnlyLeftClick = false

    var isFocusOnlyLeftClickArmed: Bool {
        focusOnlyLeftClick
    }

    mutating func clearFocusOnlyLeftClick() {
        focusOnlyLeftClick = false
    }

    mutating func armFocusOnlyLeftClick() {
        focusOnlyLeftClick = true
    }

    mutating func mouseDown(
        button: Button,
        surfaceIdentity: SurfaceIdentity?
    ) -> GhosttyMouseButtonPolicyDecision {
        if button == .left, focusOnlyLeftClick {
            focusOnlyLeftClick = false
            pendingReleases[button] = .suppressed
            return .suppress
        }

        guard let surfaceIdentity else {
            pendingReleases[button] = .suppressed
            return .suppress
        }

        pendingReleases[button] = .sent(to: surfaceIdentity)
        return .send
    }

    mutating func mouseUp(
        button: Button,
        surfaceIdentity: SurfaceIdentity?
    ) -> GhosttyMouseButtonPolicyDecision {
        guard let pendingRelease = pendingReleases.removeValue(forKey: button) else {
            return surfaceIdentity == nil ? .suppress : .send
        }

        switch pendingRelease {
        case .suppressed:
            return .suppress

        case let .sent(pressSurfaceIdentity):
            guard let surfaceIdentity, surfaceIdentity == pressSurfaceIdentity else {
                return .suppress
            }
            return .send
        }
    }
}
