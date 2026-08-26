import Testing
@testable import awesoMux

@Suite("First-run tour eligibility")
struct FirstRunTourPolicyTests {
    @Test("A brand-new install on an empty tree is eligible")
    func newInstallIsEligible() {
        #expect(FirstRunTourPolicy.shouldAutoPresent(
            hasSeenTour: false, hasPriorInstallEvidence: false, mode: .firstLaunch) == true)
    }

    @Test("An upgrading user is never greeted as new")
    func priorInstallSuppresses() {
        #expect(FirstRunTourPolicy.shouldAutoPresent(
            hasSeenTour: false, hasPriorInstallEvidence: true, mode: .firstLaunch) == false)
    }

    @Test("Dismissed once, never auto-shown again")
    func seenSuppresses() {
        #expect(FirstRunTourPolicy.shouldAutoPresent(
            hasSeenTour: true, hasPriorInstallEvidence: false, mode: .firstLaunch) == false)
    }

    @Test("A quarantined session outranks onboarding")
    func recoveredSuppresses() {
        #expect(FirstRunTourPolicy.shouldAutoPresent(
            hasSeenTour: false, hasPriorInstallEvidence: false, mode: .recovered) == false)
    }

    @Test("A returning user between workspaces is not new")
    func noSelectionSuppresses() {
        #expect(FirstRunTourPolicy.shouldAutoPresent(
            hasSeenTour: false, hasPriorInstallEvidence: false, mode: .noSelection) == false)
    }
}
