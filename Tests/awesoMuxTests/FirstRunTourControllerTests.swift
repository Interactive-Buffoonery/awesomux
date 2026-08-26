import Foundation
import Testing

@testable import awesoMux

@Suite("First-run tour controller")
@MainActor
struct FirstRunTourControllerTests {
    @Test("User dismissal marks the tour seen")
    func userDismissalPersists() {
        let defaults = UserDefaults(suiteName: "tour.ctrl.user")!
        defaults.removePersistentDomain(forName: "tour.ctrl.user")
        let controller = FirstRunTourController(defaults: defaults)
        controller.dismissByUser()
        #expect(defaults.bool(forKey: SettingsKey.hasSeenFirstRunTour) == true)
    }

    @Test("Losing key focus neither hides the tour nor marks it seen")
    func focusLossIsInert() {
        let defaults = UserDefaults(suiteName: "tour.ctrl.focus")!
        defaults.removePersistentDomain(forName: "tour.ctrl.focus")
        let controller = FirstRunTourController(defaults: defaults)
        controller.showForTesting()
        controller.handleKeyStateChangedForTesting(false)
        #expect(controller.isVisible == true)
        #expect(defaults.bool(forKey: SettingsKey.hasSeenFirstRunTour) == false)
    }

    @Test("The notification beat gates on reaching beat three")
    func notificationBeatGate() {
        let controller = FirstRunTourController(
            defaults: UserDefaults(suiteName: "tour.ctrl.beat")!)
        #expect(controller.hasReachedNotificationBeat == false)
        controller.advance()
        controller.advance()
        #expect(controller.hasReachedNotificationBeat == true)
    }

    @Test("Re-summoning resumes rather than restarting")
    func resumesAtCurrentBeat() {
        let controller = FirstRunTourController(
            defaults: UserDefaults(suiteName: "tour.ctrl.resume")!)
        controller.advance()
        controller.showForTesting()
        #expect(controller.currentBeat == 1)
    }

    // MARK: - Cmd-W routing

    @Test("Cmd-W dismisses the tour when it is the key window")
    func closeChordDismissesKeyTour() {
        let defaults = UserDefaults(suiteName: "tour.ctrl.closekey")!
        defaults.removePersistentDomain(forName: "tour.ctrl.closekey")
        let controller = FirstRunTourController(defaults: defaults)
        controller.showForTesting()
        controller.handleKeyStateChangedForTesting(true)

        #expect(controller.hideIfKeyWindow() == true)
        #expect(controller.isVisible == false)
        #expect(defaults.bool(forKey: SettingsKey.hasSeenFirstRunTour) == true)
    }

    /// The half of the guard that keeps Cmd-W from closing the tour when the
    /// user is actually aiming it at a pane behind it.
    @Test("Cmd-W falls through when the tour is visible but not key")
    func closeChordFallsThroughForNonKeyTour() {
        let defaults = UserDefaults(suiteName: "tour.ctrl.closenonkey")!
        defaults.removePersistentDomain(forName: "tour.ctrl.closenonkey")
        let controller = FirstRunTourController(defaults: defaults)
        controller.showForTesting()
        controller.handleKeyStateChangedForTesting(false)

        #expect(controller.hideIfKeyWindow() == false)
        #expect(controller.isVisible == true)
        #expect(defaults.bool(forKey: SettingsKey.hasSeenFirstRunTour) == false)
    }

    @Test("Cmd-W falls through when the tour is not visible")
    func closeChordFallsThroughForHiddenTour() {
        let defaults = UserDefaults(suiteName: "tour.ctrl.closehidden")!
        defaults.removePersistentDomain(forName: "tour.ctrl.closehidden")
        let controller = FirstRunTourController(defaults: defaults)
        controller.handleKeyStateChangedForTesting(true)

        #expect(controller.hideIfKeyWindow() == false)
        #expect(controller.isVisible == false)
        #expect(defaults.bool(forKey: SettingsKey.hasSeenFirstRunTour) == false)
    }

    // MARK: - Notification prime deferral

    @Test("The prime deferral ends at beat three, not before")
    func deferralEndsAtNotificationBeat() {
        let controller = FirstRunTourController(
            defaults: UserDefaults(suiteName: "tour.ctrl.deferbeat")!)
        #expect(controller.isDeferringNotificationPrime == false)

        controller.showForTesting()
        #expect(controller.isDeferringNotificationPrime == true)
        controller.advance()
        #expect(controller.isDeferringNotificationPrime == true)
        controller.advance()
        #expect(controller.isDeferringNotificationPrime == false)
    }

    /// The real failure path: beat one tells the user to press ⌘N, the chord is
    /// live over the tour, so the workspace mutation that would have primed
    /// happens *during* the deferral. Paging on to Done mutates nothing else, so
    /// this signal is the only thing that can bring the evaluation back.
    @Test("Finishing the tour releases a prime deferred at beat one")
    func dismissalReleasesDeferredPrime() {
        let defaults = UserDefaults(suiteName: "tour.ctrl.deferprime")!
        defaults.removePersistentDomain(forName: "tour.ctrl.deferprime")
        let controller = FirstRunTourController(defaults: defaults)
        controller.showForTesting()

        func inputs() -> NotificationPrimePolicy.Inputs {
            .init(
                hasEligibleSession: true,
                isLaunchEvaluation: false,
                tourIsVisible: controller.isVisible,
                tourReachedNotificationBeat: controller.hasReachedNotificationBeat,
                anyChannelEnabled: true,
                requestInFlight: false,
                isNotDetermined: true)
        }

        #expect(controller.isDeferringNotificationPrime == true)
        #expect(NotificationPrimePolicy.shouldPrime(inputs()) == false)

        controller.dismissByUser()

        #expect(controller.isDeferringNotificationPrime == false)
        #expect(NotificationPrimePolicy.shouldPrime(inputs()) == true)
    }
}
