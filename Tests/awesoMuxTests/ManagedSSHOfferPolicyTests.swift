import AwesoMuxConfig
import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("Managed SSH offer policy")
struct ManagedSSHOfferPolicyTests {
    @Test("enabled offers ask for destinations not on the ignored list")
    func enabledOffersAskForUnlistedDestinations() throws {
        let target = try #require(RemoteTarget(parsing: "build-box"))

        #expect(ManagedSSHOfferPolicy.decision(target: target, config: .defaultValue) == .offer)
    }

    @Test("disabled offers suppress every destination")
    func disabledOffersSuppressEveryDestination() throws {
        let target = try #require(RemoteTarget(parsing: "build-box"))
        let config = WorkspaceConfig(managedSSHOffersEnabled: false)

        #expect(ManagedSSHOfferPolicy.decision(target: target, config: config) == .none)
    }

    @Test("ignored destinations use exact normalized OpenSSH identity")
    func ignoredDestinationsUseExactNormalizedIdentity() throws {
        let ignored = try #require(RemoteTarget(parsing: "deploy@build-box"))
        let other = try #require(RemoteTarget(parsing: "build-box"))
        let config = WorkspaceConfig(
            managedSSHOfferIgnoredDestinations: ["  deploy@build-box  "]
        )

        #expect(ManagedSSHOfferPolicy.decision(target: ignored, config: config) == .none)
        #expect(ManagedSSHOfferPolicy.decision(target: other, config: config) == .offer)
    }

    @Test("invalid persisted destinations cannot suppress an offer")
    func invalidPersistedDestinationsCannotSuppressOffer() throws {
        let target = try #require(RemoteTarget(parsing: "build-box"))
        let config = WorkspaceConfig(
            managedSSHOfferIgnoredDestinations: ["-oProxyCommand=build-box", "user@"]
        )

        #expect(ManagedSSHOfferPolicy.decision(target: target, config: config) == .offer)
    }

    @Test("a destination on the always-managed list connects without asking")
    func alwaysManagedDestinationsConnectAutomatically() throws {
        let target = try #require(RemoteTarget(parsing: "deploy@build-box"))
        let config = WorkspaceConfig(
            managedSSHAlwaysManagedDestinations: ["deploy@build-box"]
        )

        #expect(ManagedSSHOfferPolicy.decision(target: target, config: config) == .connectAutomatically)
    }

    @Test("the always list wins over disabled offers and a stale ignore entry")
    func alwaysListBeatsSuppression() throws {
        let target = try #require(RemoteTarget(parsing: "build-box"))
        let config = WorkspaceConfig(
            managedSSHOffersEnabled: false,
            managedSSHOfferIgnoredDestinations: ["build-box"],
            managedSSHAlwaysManagedDestinations: ["build-box"]
        )

        #expect(ManagedSSHOfferPolicy.decision(target: target, config: config) == .connectAutomatically)
    }

    @Test("the global always toggle connects automatically even with offers off")
    func globalAlwaysBeatsDisabledOffers() throws {
        let target = try #require(RemoteTarget(parsing: "build-box"))
        var config = WorkspaceConfig(managedSSHOffersEnabled: false)
        config.managedSSHAlwaysManageAllDestinations = true

        #expect(ManagedSSHOfferPolicy.decision(target: target, config: config) == .connectAutomatically)
    }

    @Test("invalid persisted always entries cannot auto-connect")
    func invalidPersistedDestinationsCannotAutoConnect() throws {
        let target = try #require(RemoteTarget(parsing: "build-box"))
        let config = WorkspaceConfig(
            managedSSHAlwaysManagedDestinations: ["-oProxyCommand=build-box", "user@"]
        )

        #expect(ManagedSSHOfferPolicy.decision(target: target, config: config) == .offer)
    }

    @Test("adding an always destination stores its normalized identity")
    func addingAlwaysDestinationStoresNormalizedIdentity() {
        var config = WorkspaceConfig()

        let result = ManagedSSHOfferPolicy.addAlwaysManagedDestination("  deploy@build-box  ", to: &config)

        #expect(result == .added("deploy@build-box"))
        #expect(config.managedSSHAlwaysManagedDestinations == ["deploy@build-box"])
    }

    @Test("adding an invalid or duplicate always destination changes nothing")
    func invalidOrDuplicateAlwaysAdditionChangesNothing() {
        var config = WorkspaceConfig(
            managedSSHAlwaysManagedDestinations: ["build-box"]
        )

        #expect(ManagedSSHOfferPolicy.addAlwaysManagedDestination("build-box", to: &config) == .duplicate)
        #expect(ManagedSSHOfferPolicy.addAlwaysManagedDestination("-oProxyCommand=bad", to: &config) == .invalid)
        #expect(config.managedSSHAlwaysManagedDestinations == ["build-box"])
    }

    @Test("the two lists stay disjoint whichever one is chosen")
    func listsStayDisjoint() {
        var config = WorkspaceConfig()

        _ = ManagedSSHOfferPolicy.addIgnoredDestination("build-box", to: &config)
        _ = ManagedSSHOfferPolicy.addAlwaysManagedDestination("build-box", to: &config)
        #expect(config.managedSSHAlwaysManagedDestinations == ["build-box"])
        #expect(config.managedSSHOfferIgnoredDestinations.isEmpty)

        _ = ManagedSSHOfferPolicy.addIgnoredDestination("staging", to: &config)
        _ = ManagedSSHOfferPolicy.addIgnoredDestination("build-box", to: &config)
        #expect(config.managedSSHOfferIgnoredDestinations.contains("build-box"))
        #expect(!config.managedSSHAlwaysManagedDestinations.contains("build-box"))
    }

    @Test("removing an always destination restores its offer eligibility")
    func removingAlwaysDestinationRestoresOfferEligibility() throws {
        let target = try #require(RemoteTarget(parsing: "build-box"))
        var config = WorkspaceConfig(
            managedSSHAlwaysManagedDestinations: ["build-box", "staging"]
        )

        ManagedSSHOfferPolicy.removeAlwaysManagedDestination("build-box", from: &config)

        #expect(config.managedSSHAlwaysManagedDestinations == ["staging"])
        #expect(ManagedSSHOfferPolicy.decision(target: target, config: config) == .offer)
    }

    @Test("adding a destination stores its normalized identity")
    func addingDestinationStoresNormalizedIdentity() {
        var config = WorkspaceConfig()

        let result = ManagedSSHOfferPolicy.addIgnoredDestination("  deploy@build-box  ", to: &config)

        #expect(result == .added("deploy@build-box"))
        #expect(config.managedSSHOfferIgnoredDestinations == ["deploy@build-box"])
    }

    @Test("adding an invalid or duplicate destination changes nothing")
    func invalidOrDuplicateAdditionChangesNothing() {
        var config = WorkspaceConfig(
            managedSSHOfferIgnoredDestinations: ["build-box"]
        )

        #expect(ManagedSSHOfferPolicy.addIgnoredDestination("build-box", to: &config) == .duplicate)
        #expect(ManagedSSHOfferPolicy.addIgnoredDestination("-oProxyCommand=bad", to: &config) == .invalid)
        #expect(config.managedSSHOfferIgnoredDestinations == ["build-box"])
    }

    @Test("removing a destination restores its offer eligibility")
    func removingDestinationRestoresOfferEligibility() throws {
        let target = try #require(RemoteTarget(parsing: "build-box"))
        var config = WorkspaceConfig(
            managedSSHOfferIgnoredDestinations: ["build-box", "staging"]
        )

        ManagedSSHOfferPolicy.removeIgnoredDestination("build-box", from: &config)

        #expect(config.managedSSHOfferIgnoredDestinations == ["staging"])
        #expect(ManagedSSHOfferPolicy.decision(target: target, config: config) == .offer)
    }
}
