import AwesoMuxConfig
import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("Managed SSH offer policy")
struct ManagedSSHOfferPolicyTests {
    @Test("enabled offers ask for destinations not on the ignored list")
    func enabledOffersAskForUnlistedDestinations() throws {
        let target = try #require(RemoteTarget(parsing: "build-box"))

        #expect(ManagedSSHOfferPolicy.shouldOffer(target: target, config: .defaultValue))
    }

    @Test("disabled offers suppress every destination")
    func disabledOffersSuppressEveryDestination() throws {
        let target = try #require(RemoteTarget(parsing: "build-box"))
        let config = WorkspaceConfig(managedSSHOffersEnabled: false)

        #expect(!ManagedSSHOfferPolicy.shouldOffer(target: target, config: config))
    }

    @Test("ignored destinations use exact normalized OpenSSH identity")
    func ignoredDestinationsUseExactNormalizedIdentity() throws {
        let ignored = try #require(RemoteTarget(parsing: "deploy@build-box"))
        let other = try #require(RemoteTarget(parsing: "build-box"))
        let config = WorkspaceConfig(
            managedSSHOfferIgnoredDestinations: ["  deploy@build-box  "]
        )

        #expect(!ManagedSSHOfferPolicy.shouldOffer(target: ignored, config: config))
        #expect(ManagedSSHOfferPolicy.shouldOffer(target: other, config: config))
    }

    @Test("invalid persisted destinations cannot suppress an offer")
    func invalidPersistedDestinationsCannotSuppressOffer() throws {
        let target = try #require(RemoteTarget(parsing: "build-box"))
        let config = WorkspaceConfig(
            managedSSHOfferIgnoredDestinations: ["-oProxyCommand=build-box", "user@"]
        )

        #expect(ManagedSSHOfferPolicy.shouldOffer(target: target, config: config))
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
        #expect(ManagedSSHOfferPolicy.shouldOffer(target: target, config: config))
    }
}
