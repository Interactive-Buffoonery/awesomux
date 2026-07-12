import Testing
@testable import awesoMux

@Suite("Ghostty mouse focus click policy")
struct GhosttyMouseFocusClickPolicyTests {
    @Test("focus-only click is suppressed and arms a pending catch-up")
    func focusOnlyClickSuppressesAndArmsPendingCatchUp() {
        let result = GhosttyMouseFocusClickPolicy.decideLeftMouseDown(
            isFocusOnlyClick: true,
            hasPendingFocusTransferClick: false,
            clickCount: 1,
            hasSurface: true,
            mouseCaptured: false
        )

        #expect(result.decision == .suppressFocusTransfer)
        #expect(result.hasPendingFocusTransferClick)
    }

    @Test("double-click after focus transfer replays the suppressed click")
    func doubleClickAfterFocusTransferReplaysSuppressedClick() {
        let result = GhosttyMouseFocusClickPolicy.decideLeftMouseDown(
            isFocusOnlyClick: false,
            hasPendingFocusTransferClick: true,
            clickCount: 2,
            hasSurface: true,
            mouseCaptured: false
        )

        #expect(result.decision == .sendPress(replaySuppressedFocusClick: true))
        #expect(!result.hasPendingFocusTransferClick)
    }

    @Test("plain click after focus transfer clears pending without replay")
    func plainClickAfterFocusTransferClearsPendingWithoutReplay() {
        let result = GhosttyMouseFocusClickPolicy.decideLeftMouseDown(
            isFocusOnlyClick: false,
            hasPendingFocusTransferClick: true,
            clickCount: 1,
            hasSurface: true,
            mouseCaptured: false
        )

        #expect(result.decision == .sendPress(replaySuppressedFocusClick: false))
        #expect(!result.hasPendingFocusTransferClick)
    }

    @Test("no live surface prevents synthetic replay")
    func noSurfacePreventsSyntheticReplay() {
        let result = GhosttyMouseFocusClickPolicy.decideLeftMouseDown(
            isFocusOnlyClick: false,
            hasPendingFocusTransferClick: true,
            clickCount: 2,
            hasSurface: false,
            mouseCaptured: false
        )

        #expect(result.decision == .sendPress(replaySuppressedFocusClick: false))
        #expect(!result.hasPendingFocusTransferClick)
    }

    @Test("mouse capture prevents synthetic replay")
    func mouseCapturePreventsSyntheticReplay() {
        let result = GhosttyMouseFocusClickPolicy.decideLeftMouseDown(
            isFocusOnlyClick: false,
            hasPendingFocusTransferClick: true,
            clickCount: 2,
            hasSurface: true,
            mouseCaptured: true
        )

        #expect(result.decision == .sendPress(replaySuppressedFocusClick: false))
        #expect(!result.hasPendingFocusTransferClick)
    }

    @Test("double-click without pending focus transfer does not replay")
    func doubleClickWithoutPendingFocusTransferDoesNotReplay() {
        let result = GhosttyMouseFocusClickPolicy.decideLeftMouseDown(
            isFocusOnlyClick: false,
            hasPendingFocusTransferClick: false,
            clickCount: 2,
            hasSurface: true,
            mouseCaptured: false
        )

        #expect(result.decision == .sendPress(replaySuppressedFocusClick: false))
        #expect(!result.hasPendingFocusTransferClick)
    }
}
