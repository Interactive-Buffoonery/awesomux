import AwesoMuxConfig
import Foundation
import Testing
@testable import awesoMux

@Suite("First-run tour eligibility")
struct FirstRunTourPolicyTests {
    @Test("A brand-new install on an empty tree is eligible")
    func newInstallIsEligible() {
        #expect(
            FirstRunTourPolicy.shouldAutoPresent(
                hasSeenTour: false, hasPriorInstallEvidence: false, mode: .firstLaunch) == true)
    }

    @Test("An upgrading user is never greeted as new")
    func priorInstallSuppresses() {
        #expect(
            FirstRunTourPolicy.shouldAutoPresent(
                hasSeenTour: false, hasPriorInstallEvidence: true, mode: .firstLaunch) == false)
    }

    @Test("Dismissed once, never auto-shown again")
    func seenSuppresses() {
        #expect(
            FirstRunTourPolicy.shouldAutoPresent(
                hasSeenTour: true, hasPriorInstallEvidence: false, mode: .firstLaunch) == false)
    }

    @Test("A quarantined session outranks onboarding")
    func recoveredSuppresses() {
        #expect(
            FirstRunTourPolicy.shouldAutoPresent(
                hasSeenTour: false, hasPriorInstallEvidence: false, mode: .recovered) == false)
    }

    @Test("A returning user between workspaces is not new")
    func noSelectionSuppresses() {
        #expect(
            FirstRunTourPolicy.shouldAutoPresent(
                hasSeenTour: false, hasPriorInstallEvidence: false, mode: .noSelection) == false)
    }

    @Test("Only a freshly-created config counts as no prior install")
    func evidenceSources() {
        #expect(FirstRunTourPolicy.hasPriorInstallEvidence(loadSource: .createdDefault) == false)
        #expect(FirstRunTourPolicy.hasPriorInstallEvidence(loadSource: .existingFile) == true)
        #expect(FirstRunTourPolicy.hasPriorInstallEvidence(loadSource: .migratedLegacy) == true)
        #expect(FirstRunTourPolicy.hasPriorInstallEvidence(loadSource: .invalidExistingFile) == true)
        #expect(FirstRunTourPolicy.hasPriorInstallEvidence(loadSource: .unreadableExistingFile) == true)
        // Bootstrap threw and never set a source — an unknown history is not
        // license to re-onboard a possibly-returning user.
        #expect(FirstRunTourPolicy.hasPriorInstallEvidence(loadSource: nil) == true)
    }

    @Test("Seeding marks an upgrading install as already seen")
    func seedingWritesFlagOnlyForPriorInstalls() {
        let upgraded = UserDefaults(suiteName: "tour.seed.upgraded")!
        upgraded.removePersistentDomain(forName: "tour.seed.upgraded")
        FirstRunTourPolicy.seedSeenFlagIfNeeded(defaults: upgraded, hasPriorInstallEvidence: true)
        #expect(upgraded.bool(forKey: SettingsKey.hasSeenFirstRunTour) == true)

        let fresh = UserDefaults(suiteName: "tour.seed.fresh")!
        fresh.removePersistentDomain(forName: "tour.seed.fresh")
        FirstRunTourPolicy.seedSeenFlagIfNeeded(defaults: fresh, hasPriorInstallEvidence: false)
        #expect(fresh.bool(forKey: SettingsKey.hasSeenFirstRunTour) == false)
    }
}
