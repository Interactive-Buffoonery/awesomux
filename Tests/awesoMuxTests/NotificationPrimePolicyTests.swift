import Testing
@testable import awesoMux

@Suite("Notification prime triggers")
struct NotificationPrimePolicyTests {
    private func inputs(
        hasEligibleSession: Bool = true,
        isLaunchEvaluation: Bool = false,
        tourIsVisible: Bool = false,
        tourReachedNotificationBeat: Bool = false,
        anyChannelEnabled: Bool = true,
        requestInFlight: Bool = false,
        isNotDetermined: Bool = true
    ) -> NotificationPrimePolicy.Inputs {
        .init(
            hasEligibleSession: hasEligibleSession,
            isLaunchEvaluation: isLaunchEvaluation,
            tourIsVisible: tourIsVisible,
            tourReachedNotificationBeat: tourReachedNotificationBeat,
            anyChannelEnabled: anyChannelEnabled,
            requestInFlight: requestInFlight,
            isNotDetermined: isNotDetermined)
    }

    @Test("Zero-to-one session primes")
    func firstSessionPrimes() {
        #expect(NotificationPrimePolicy.shouldPrime(inputs()) == true)
    }

    @Test("Never at launch, even with restored workspaces")
    func launchNeverPrimes() {
        #expect(NotificationPrimePolicy.shouldPrime(
            inputs(isLaunchEvaluation: true)) == false)
    }

    @Test("No session means nothing to notify about")
    func noSessionDoesNotPrime() {
        #expect(NotificationPrimePolicy.shouldPrime(
            inputs(hasEligibleSession: false)) == false)
    }

    @Test("Deferred while the tour is visible before its notification beat")
    func tourBeforeBeatDefers() {
        #expect(NotificationPrimePolicy.shouldPrime(
            inputs(tourIsVisible: true, tourReachedNotificationBeat: false)) == false)
    }

    @Test("Allowed once the tour has explained notifications")
    func tourAfterBeatPrimes() {
        #expect(NotificationPrimePolicy.shouldPrime(
            inputs(tourIsVisible: true, tourReachedNotificationBeat: true)) == true)
    }

    @Test("Both channels off means the bridge would no-op anyway")
    func channelsOffDoesNotPrime() {
        #expect(NotificationPrimePolicy.shouldPrime(
            inputs(anyChannelEnabled: false)) == false)
    }

    @Test("An in-flight request is not duplicated")
    func inFlightDoesNotPrime() {
        #expect(NotificationPrimePolicy.shouldPrime(
            inputs(requestInFlight: true)) == false)
    }

    @Test("Already decided means nothing to ask")
    func determinedDoesNotPrime() {
        #expect(NotificationPrimePolicy.shouldPrime(
            inputs(isNotDetermined: false)) == false)
    }
}
