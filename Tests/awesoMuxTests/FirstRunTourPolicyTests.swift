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

    @Test("Either artifact counts as prior use")
    func evidenceSources() {
        #expect(
            FirstRunTourPolicy.hasPriorInstallEvidence(
                snapshotExists: true, configDirectoryExists: false) == true)
        #expect(
            FirstRunTourPolicy.hasPriorInstallEvidence(
                snapshotExists: false, configDirectoryExists: true) == true)
        #expect(
            FirstRunTourPolicy.hasPriorInstallEvidence(
                snapshotExists: false, configDirectoryExists: false) == false)
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
