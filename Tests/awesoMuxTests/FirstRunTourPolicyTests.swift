import AwesoMuxConfig
import Foundation
import Testing
@testable import awesoMux

@Suite("First-run tour eligibility")
struct FirstRunTourPolicyTests {
    /// A suite name that no other test shares, wiped before use. The
    /// registration domain is process-wide, so `hasSeenFirstRunTour` is
    /// deliberately absent from `SettingsDefault.registerInitialValues` —
    /// registering it would make `object(forKey:)` non-nil here and everywhere.
    private func freshDefaults(_ suite: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("A brand-new install on an empty tree is eligible")
    func newInstallIsEligible() {
        #expect(FirstRunTourPolicy.shouldAutoPresent(seenFlag: false, mode: .firstLaunch) == true)
    }

    @Test("An upgrading user is never greeted as new")
    func priorInstallSuppresses() {
        #expect(FirstRunTourPolicy.shouldAutoPresent(seenFlag: true, mode: .firstLaunch) == false)
    }

    /// The flag is three-valued on purpose: unwritten means this launch's
    /// bootstrap failed and nothing has ever classified the install.
    @Test("An unclassified install is not re-onboarded on a guess")
    func unseededSuppresses() {
        #expect(FirstRunTourPolicy.shouldAutoPresent(seenFlag: nil, mode: .firstLaunch) == false)
    }

    @Test("A quarantined session outranks onboarding")
    func recoveredSuppresses() {
        #expect(FirstRunTourPolicy.shouldAutoPresent(seenFlag: false, mode: .recovered) == false)
    }

    @Test("A returning user between workspaces is not new")
    func noSelectionSuppresses() {
        #expect(FirstRunTourPolicy.shouldAutoPresent(seenFlag: false, mode: .noSelection) == false)
    }

    @Test("Only a freshly-created config counts as no prior install")
    func evidenceSources() {
        #expect(FirstRunTourPolicy.hasPriorInstallEvidence(loadSource: .createdDefault) == false)
        #expect(FirstRunTourPolicy.hasPriorInstallEvidence(loadSource: .existingFile) == true)
        #expect(FirstRunTourPolicy.hasPriorInstallEvidence(loadSource: .migratedLegacy) == true)
        #expect(FirstRunTourPolicy.hasPriorInstallEvidence(loadSource: .invalidExistingFile) == true)
        #expect(FirstRunTourPolicy.hasPriorInstallEvidence(loadSource: .unreadableExistingFile) == true)
    }

    @Test("Seeding classifies an upgrading install as already seen")
    func seedingClassifiesUpgrade() {
        let defaults = freshDefaults("tour.seed.upgraded")
        FirstRunTourPolicy.seedSeenFlagIfNeeded(defaults: defaults, loadSource: .existingFile)
        #expect(FirstRunTourPolicy.seenFlag(defaults: defaults) == true)
    }

    /// The seed writes `false` for a genuinely new install rather than leaving
    /// the key absent — that write is what makes launch two a no-op.
    @Test("Seeding records a brand-new install explicitly")
    func seedingClassifiesNewInstall() {
        let defaults = freshDefaults("tour.seed.fresh")
        FirstRunTourPolicy.seedSeenFlagIfNeeded(defaults: defaults, loadSource: .createdDefault)
        #expect(FirstRunTourPolicy.seenFlag(defaults: defaults) == false)
    }

    /// The regression this whole seeding rule exists for. A genuinely new user
    /// launches, gets the tour, and quits (or crashes, or never reaches the
    /// scene's `.onAppear`) without dismissing it. Launch two reads
    /// `.existingFile` — the config launch one wrote itself — and must not
    /// reclassify them as a returning user.
    @Test("An interrupted first launch is still eligible on launch two")
    func interruptedFirstLaunchStaysEligible() {
        let defaults = freshDefaults("tour.seed.interrupted")

        FirstRunTourPolicy.seedSeenFlagIfNeeded(defaults: defaults, loadSource: .createdDefault)
        FirstRunTourPolicy.seedSeenFlagIfNeeded(defaults: defaults, loadSource: .existingFile)

        #expect(FirstRunTourPolicy.seenFlag(defaults: defaults) == false)
        #expect(
            FirstRunTourPolicy.shouldAutoPresent(
                seenFlag: FirstRunTourPolicy.seenFlag(defaults: defaults),
                mode: .firstLaunch) == true)
    }

    /// Dismissal is the one thing that may flip the flag to `true`; a later
    /// launch must not undo it either.
    @Test("A dismissed tour stays dismissed across launches")
    func dismissalSurvivesReseeding() {
        let defaults = freshDefaults("tour.seed.dismissed")
        FirstRunTourPolicy.seedSeenFlagIfNeeded(defaults: defaults, loadSource: .createdDefault)
        defaults.set(true, forKey: SettingsKey.hasSeenFirstRunTour)

        FirstRunTourPolicy.seedSeenFlagIfNeeded(defaults: defaults, loadSource: .existingFile)

        #expect(FirstRunTourPolicy.seenFlag(defaults: defaults) == true)
    }

    /// A bootstrap failure knows nothing, so it must persist nothing —
    /// otherwise repairing the profile later could never restore onboarding.
    @Test("A failed bootstrap persists no classification")
    func failedBootstrapDoesNotSeed() {
        let defaults = freshDefaults("tour.seed.nobootstrap")

        FirstRunTourPolicy.seedSeenFlagIfNeeded(defaults: defaults, loadSource: nil)
        #expect(FirstRunTourPolicy.seenFlag(defaults: defaults) == nil)

        // The next healthy launch classifies it correctly.
        FirstRunTourPolicy.seedSeenFlagIfNeeded(defaults: defaults, loadSource: .createdDefault)
        #expect(FirstRunTourPolicy.seenFlag(defaults: defaults) == false)
    }
}
