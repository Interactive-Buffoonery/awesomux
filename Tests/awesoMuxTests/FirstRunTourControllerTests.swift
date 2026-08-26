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
}
