import Foundation
import Testing
@testable import awesoMux

@Suite("Floating panel dismiss confirmation state")
struct FloatingPanelDismissConfirmationStateTests {
    @Test("clean dismiss proceeds immediately")
    func cleanDismissProceedsImmediately() {
        var state = FloatingPanelDismissConfirmationState()

        let decision = state.decision(hasDiscardRisk: false)
        #expect(decision == .dismiss)
        #expect(!state.isPending)
    }

    @Test("risky dismiss requires a second request")
    func riskyDismissRequiresSecondRequest() {
        var state = FloatingPanelDismissConfirmationState()

        let firstDismiss = state.decision(hasDiscardRisk: true)
        #expect(firstDismiss == .needsConfirmation)
        #expect(state.isPending)

        let secondDismiss = state.decision(hasDiscardRisk: true)
        #expect(secondDismiss == .discardConfirmed)
        #expect(!state.isPending)
    }

    @Test("clean state clears a pending confirmation")
    func cleanStateClearsPendingConfirmation() {
        var state = FloatingPanelDismissConfirmationState()

        let firstDismiss = state.decision(hasDiscardRisk: true)
        #expect(firstDismiss == .needsConfirmation)
        #expect(state.isPending)

        let cleanDismiss = state.decision(hasDiscardRisk: false)
        #expect(cleanDismiss == .dismiss)
        #expect(!state.isPending)
    }

    @Test("non-Escape risky dismiss hides without arming or confirming")
    func nonEscapeRiskyDismissHidesWithoutArming() {
        var state = FloatingPanelDismissConfirmationState()

        let firstDismiss = state.decision(hasDiscardRisk: true)
        #expect(firstDismiss == .needsConfirmation)
        #expect(state.isPending)

        let toggleDismiss = state.decision(hasDiscardRisk: true, source: .nonEscape)
        #expect(toggleDismiss == .hide)
        #expect(!state.isPending)
    }

    @Test("pending confirmation expires")
    func pendingConfirmationExpires() {
        var state = FloatingPanelDismissConfirmationState()
        let now = Date()

        let firstDismiss = state.decision(hasDiscardRisk: true, now: now)
        #expect(firstDismiss == .needsConfirmation)
        #expect(state.isPending)

        let expiredDismiss = state.decision(
            hasDiscardRisk: true,
            now: now.addingTimeInterval(
                FloatingPanelDismissConfirmationState.pendingConfirmationTimeout
            )
        )
        #expect(expiredDismiss == .needsConfirmation)
        #expect(state.isPending)
    }
}
