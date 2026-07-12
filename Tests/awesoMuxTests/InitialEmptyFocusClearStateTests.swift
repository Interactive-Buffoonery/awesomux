import Testing
@testable import awesoMux

@Suite("Initial empty focus clear")
struct InitialEmptyFocusClearStateTests {
    @Test("waits for the hosting window to become key")
    func waitsForHostingWindowKeyTransition() {
        var state = InitialEmptyFocusClearState()

        state.requestIfNeeded(hasSelectedSession: false)

        let clearedWhileNotKey = state.consumeIfEligible(
            hasSelectedSession: false,
            isHostingWindowKey: false
        )
        #expect(state.isPending)
        let clearedAfterBecomingKey = state.consumeIfEligible(
            hasSelectedSession: false,
            isHostingWindowKey: true
        )

        #expect(!clearedWhileNotKey)
        #expect(clearedAfterBecomingKey)
        #expect(!state.isPending)
    }

    @Test("clears only once after becoming eligible")
    func clearsOnlyOnce() {
        var state = InitialEmptyFocusClearState()

        state.requestIfNeeded(hasSelectedSession: false)

        let firstAttempt = state.consumeIfEligible(
            hasSelectedSession: false,
            isHostingWindowKey: true
        )
        let secondAttempt = state.consumeIfEligible(
            hasSelectedSession: false,
            isHostingWindowKey: true
        )

        #expect(firstAttempt)
        #expect(!secondAttempt)
    }

    @Test("cancels when a session claims focus first")
    func cancelsWhenSessionAppears() {
        var state = InitialEmptyFocusClearState()

        state.requestIfNeeded(hasSelectedSession: false)

        let attemptAfterSessionAppears = state.consumeIfEligible(
            hasSelectedSession: true,
            isHostingWindowKey: true
        )
        #expect(!state.isPending)
        let laterAttempt = state.consumeIfEligible(
            hasSelectedSession: false,
            isHostingWindowKey: true
        )

        #expect(!attemptAfterSessionAppears)
        #expect(!laterAttempt)
    }

    @Test("does not arm for a populated launch")
    func ignoresPopulatedLaunch() {
        var state = InitialEmptyFocusClearState()

        state.requestIfNeeded(hasSelectedSession: true)
        state.requestIfNeeded(hasSelectedSession: false)

        let attempt = state.consumeIfEligible(
            hasSelectedSession: false,
            isHostingWindowKey: true
        )

        #expect(!attempt)
    }
}
