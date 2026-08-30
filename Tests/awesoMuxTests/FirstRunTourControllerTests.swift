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

    /// `showForTesting()` routes through the same `beginPresentation()` the real
    /// `show()` calls, so this covers the presentation transition rather than a
    /// parallel copy of it. (The window half of `show()` can't run headless.)
    @Test("Re-summoning resumes rather than restarting")
    func resumesAtCurrentBeat() {
        let controller = FirstRunTourController(
            defaults: UserDefaults(suiteName: "tour.ctrl.resume")!)
        controller.advance()
        controller.showForTesting()
        #expect(controller.currentBeat == 1)
    }

    /// The panel is reused across dismiss (`orderOut`, not `close`) and only its
    /// `rootView` is swapped, so the page's `@State` survives. Presentation has
    /// to be observable from the page or a recall never moves VoiceOver focus.
    @Test("Every presentation is distinguishable to the hosted page")
    func presentationTokenChangesPerShow() {
        let defaults = UserDefaults(suiteName: "tour.ctrl.token")!
        defaults.removePersistentDomain(forName: "tour.ctrl.token")
        let controller = FirstRunTourController(defaults: defaults)

        let first = controller.presentationToken
        controller.showForTesting()
        let second = controller.presentationToken
        controller.dismissByUser()
        controller.showForTesting()

        #expect(second != first)
        #expect(controller.presentationToken != second)
    }

    /// Beat five's own copy promises the "?" button brings the tour back. A user
    /// who finishes normally must not land on the closing screen, whose only
    /// remaining control is Done.
    @Test("Finishing on the last beat restarts the next recall")
    func completingResetsToFirstBeat() {
        let defaults = UserDefaults(suiteName: "tour.ctrl.complete")!
        defaults.removePersistentDomain(forName: "tour.ctrl.complete")
        let controller = FirstRunTourController(defaults: defaults)
        controller.showForTesting()
        for _ in 0..<FirstRunTourController.beatCount { controller.advance() }
        #expect(controller.currentBeat == FirstRunTourController.beatCount - 1)

        controller.dismissByUser()
        controller.showForTesting()

        #expect(controller.currentBeat == 0)
    }

    @Test("Skipping mid-tour still resumes where it left off")
    func skippingMidTourResumes() {
        let defaults = UserDefaults(suiteName: "tour.ctrl.skipmid")!
        defaults.removePersistentDomain(forName: "tour.ctrl.skipmid")
        let controller = FirstRunTourController(defaults: defaults)
        controller.showForTesting()
        controller.advance()

        controller.dismissByUser()
        controller.showForTesting()

        #expect(controller.currentBeat == 1)
    }

    // MARK: - Agent Settings handoff

    @Test("Closing agent Settings resumes the same tour beat")
    func agentSettingsCloseResumesSameBeat() {
        let controller = FirstRunTourController(
            defaults: UserDefaults(suiteName: "tour.ctrl.settingsresume")!)
        var settingsOpenCount = 0
        controller.onOpenAgentSettings = { settingsOpenCount += 1 }
        controller.showForTesting()
        controller.advance()
        controller.advance()
        let presentationBeforeSettings = controller.presentationToken

        controller.openAgentSettingsFromTour()
        let didResume = controller.resumeAfterAgentSettingsCloseForTesting()

        #expect(settingsOpenCount == 1)
        #expect(didResume == true)
        #expect(controller.currentBeat == FirstRunTourController.notificationBeatIndex)
        #expect(controller.presentationToken != presentationBeforeSettings)
        #expect(controller.isVisible == true)
    }

    @Test("An ordinary Settings close does not present the tour")
    func ordinarySettingsCloseIsInert() {
        let controller = FirstRunTourController(
            defaults: UserDefaults(suiteName: "tour.ctrl.settingsordinary")!)

        #expect(controller.resumeAfterAgentSettingsCloseForTesting() == false)
        #expect(controller.isVisible == false)
        #expect(controller.presentationToken == 0)
    }

    @Test("The agent Settings handoff is consumed once")
    func agentSettingsCloseIsOneShot() {
        let controller = FirstRunTourController(
            defaults: UserDefaults(suiteName: "tour.ctrl.settingsoneshot")!)
        controller.openAgentSettingsFromTour()

        #expect(controller.resumeAfterAgentSettingsCloseForTesting() == true)
        let presentationAfterResume = controller.presentationToken
        #expect(controller.resumeAfterAgentSettingsCloseForTesting() == false)
        #expect(controller.presentationToken == presentationAfterResume)
    }

    @Test("Explicit dismissal cancels the agent Settings handoff")
    func dismissalCancelsAgentSettingsResume() {
        let defaults = UserDefaults(suiteName: "tour.ctrl.settingsdismiss")!
        defaults.removePersistentDomain(forName: "tour.ctrl.settingsdismiss")
        let controller = FirstRunTourController(defaults: defaults)
        controller.showForTesting()
        controller.openAgentSettingsFromTour()

        controller.dismissByUser()

        #expect(controller.resumeAfterAgentSettingsCloseForTesting() == false)
        #expect(controller.isVisible == false)
        #expect(defaults.bool(forKey: SettingsKey.hasSeenFirstRunTour) == true)
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

    // MARK: - Feature Atlas handoff

    @Test("The closing-page discovery action completes the tour and opens the atlas once")
    func discoveryActionHandsOffOnce() {
        let defaults = UserDefaults(suiteName: "tour.ctrl.atlas")!
        defaults.removePersistentDomain(forName: "tour.ctrl.atlas")
        let controller = FirstRunTourController(defaults: defaults)
        var openCount = 0
        controller.onOpenFeatureAtlas = { openCount += 1 }
        controller.showForTesting()
        for _ in 1..<FirstRunTourController.beatCount { controller.advance() }

        controller.discoverFeatures()
        controller.discoverFeatures()

        #expect(openCount == 1)
        #expect(controller.isVisible == false)
        #expect(controller.currentBeat == 0)
        #expect(defaults.bool(forKey: SettingsKey.hasSeenFirstRunTour) == true)
    }

    @Test("Ordinary tour dismissal never opens the atlas")
    func dismissalDoesNotOpenAtlas() {
        let controller = FirstRunTourController(
            defaults: UserDefaults(suiteName: "tour.ctrl.noatlas")!)
        var openCount = 0
        controller.onOpenFeatureAtlas = { openCount += 1 }
        controller.showForTesting()

        controller.dismissByUser()

        #expect(openCount == 0)
    }
}
