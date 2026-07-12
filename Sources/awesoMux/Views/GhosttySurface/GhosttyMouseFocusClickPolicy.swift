enum GhosttyMouseFocusClickDecision: Equatable {
    case suppressFocusTransfer
    case sendPress(replaySuppressedFocusClick: Bool)
}

enum GhosttyMouseFocusClickPolicy {
    static func decideLeftMouseDown(
        isFocusOnlyClick: Bool,
        hasPendingFocusTransferClick: Bool,
        clickCount: Int,
        hasSurface: Bool,
        mouseCaptured: Bool
    ) -> (decision: GhosttyMouseFocusClickDecision, hasPendingFocusTransferClick: Bool) {
        if isFocusOnlyClick {
            return (.suppressFocusTransfer, true)
        }

        let shouldReplaySuppressedFocusClick = hasPendingFocusTransferClick
            && clickCount > 1
            && hasSurface
            && !mouseCaptured

        return (
            .sendPress(replaySuppressedFocusClick: shouldReplaySuppressedFocusClick),
            false
        )
    }
}
