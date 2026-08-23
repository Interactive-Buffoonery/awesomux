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
            managedSSHAlwaysManaged: alwaysManaged("deploy@build-box")
        )

        #expect(
            ManagedSSHOfferPolicy.decision(target: target, config: config)
                == .connectAutomatically(sessionName: nil)
        )
    }

    @Test("the always list wins over disabled offers, which are only a blanket answer")
    func alwaysListBeatsDisabledOffers() throws {
        // "Don't ask me" and "always manage this one" are not in conflict:
        // together they say manage it silently. Only an explicit per-destination
        // decline contradicts a per-destination grant.
        let target = try #require(RemoteTarget(parsing: "build-box"))
        let config = WorkspaceConfig(
            managedSSHOffersEnabled: false,
            managedSSHAlwaysManaged: alwaysManaged("build-box")
        )

        #expect(
            ManagedSSHOfferPolicy.decision(target: target, config: config)
                == .connectAutomatically(sessionName: nil)
        )
    }

    @Test("a destination in both lists fails safe instead of auto-connecting")
    func staleOverlapFailsSafe() throws {
        // The add APIs keep the lists disjoint, so this state only arrives by
        // hand-editing the config. Both entries are per-destination and they
        // contradict each other, so the answer goes to the option with no side
        // effects rather than silently converting the pane.
        let target = try #require(RemoteTarget(parsing: "build-box"))
        let config = WorkspaceConfig(
            managedSSHOffersEnabled: false,
            managedSSHOfferIgnoredDestinations: ["build-box"],
            managedSSHAlwaysManaged: alwaysManaged("build-box")
        )

        #expect(ManagedSSHOfferPolicy.decision(target: target, config: config) == .none)
    }

    @Test("a blanket decline outranks the blanket always toggle")
    func disabledOffersBeatGlobalAlways() throws {
        // Both are blanket answers, so neither is more specific — and the user
        // reaches this state by picking "Never Ask for Any Destination", often
        // in the sheet a failed auto-connect just put in front of them. Under
        // the reverse order that choice changed nothing at all.
        let target = try #require(RemoteTarget(parsing: "build-box"))
        var config = WorkspaceConfig(managedSSHOffersEnabled: false)
        config.managedSSHAlwaysManageAllDestinations = true

        #expect(ManagedSSHOfferPolicy.decision(target: target, config: config) == .none)
    }

    @Test("an explicit per-destination decline outranks the blanket always toggle")
    func ignoredDestinationBeatsGlobalAlways() throws {
        let ignored = try #require(RemoteTarget(parsing: "prod-db"))
        let other = try #require(RemoteTarget(parsing: "build-box"))
        var config = WorkspaceConfig(managedSSHOfferIgnoredDestinations: ["prod-db"])
        config.managedSSHAlwaysManageAllDestinations = true

        #expect(ManagedSSHOfferPolicy.decision(target: ignored, config: config) == .none)
        #expect(
            ManagedSSHOfferPolicy.decision(target: other, config: config)
                == .connectAutomatically(sessionName: nil)
        )
    }

    @Test("a remembered remote session name survives into the automatic decision")
    func rememberedRemoteSessionNameSurvives() throws {
        let target = try #require(RemoteTarget(parsing: "prod"))
        let sessionName = try #require(RemoteSessionName(rawValue: "mysession"))
        var config = WorkspaceConfig()
        _ = ManagedSSHOfferPolicy.addAlwaysManagedDestination(
            "prod",
            sessionName: sessionName,
            to: &config
        )

        // Nil here would be the owner inversion: a remote-owned session
        // silently reconnecting through a local amx daemon on every later
        // connect, and flipping the global command bridge on to do it.
        #expect(
            ManagedSSHOfferPolicy.decision(target: target, config: config)
                == .connectAutomatically(sessionName: sessionName)
        )
    }

    @Test("an unusable stored session name asks rather than downgrading the owner")
    func unusableStoredSessionNameAsks() throws {
        let target = try #require(RemoteTarget(parsing: "prod"))
        // Only reachable by hand-editing: `addAlwaysManagedDestination` takes a
        // parsed `RemoteSessionName`. Falling back to nil would convert a
        // remote-owned entry to local-amx, which is the failure this stores
        // the owner to avoid, so the honest answer is to ask.
        let config = WorkspaceConfig(
            managedSSHAlwaysManaged: ["prod": ManagedSSHAlwaysManagedEntry(sessionName: "-badname")]
        )

        #expect(ManagedSSHOfferPolicy.decision(target: target, config: config) == .offer)
    }

    @Test("invalid persisted always entries cannot auto-connect")
    func invalidPersistedDestinationsCannotAutoConnect() throws {
        let target = try #require(RemoteTarget(parsing: "build-box"))
        let config = WorkspaceConfig(
            managedSSHAlwaysManaged: alwaysManaged("-oProxyCommand=build-box", "user@")
        )

        #expect(ManagedSSHOfferPolicy.decision(target: target, config: config) == .offer)
    }

    @Test("adding an always destination stores its normalized identity")
    func addingAlwaysDestinationStoresNormalizedIdentity() {
        var config = WorkspaceConfig()

        let result = ManagedSSHOfferPolicy.addAlwaysManagedDestination("  deploy@build-box  ", to: &config)

        #expect(result == .added("deploy@build-box"))
        #expect(Set(config.managedSSHAlwaysManaged.keys) == ["deploy@build-box"])
    }

    @Test("adding an invalid or duplicate always destination changes nothing")
    func invalidOrDuplicateAlwaysAdditionChangesNothing() {
        var config = WorkspaceConfig(
            managedSSHAlwaysManaged: alwaysManaged("build-box")
        )

        #expect(ManagedSSHOfferPolicy.addAlwaysManagedDestination("build-box", to: &config) == .duplicate)
        #expect(ManagedSSHOfferPolicy.addAlwaysManagedDestination("-oProxyCommand=bad", to: &config) == .invalid)
        #expect(Set(config.managedSSHAlwaysManaged.keys) == ["build-box"])
    }

    @Test("the two lists stay disjoint whichever one is chosen")
    func listsStayDisjoint() {
        var config = WorkspaceConfig()

        _ = ManagedSSHOfferPolicy.addIgnoredDestination("build-box", to: &config)
        _ = ManagedSSHOfferPolicy.addAlwaysManagedDestination("build-box", to: &config)
        #expect(Set(config.managedSSHAlwaysManaged.keys) == ["build-box"])
        #expect(config.managedSSHOfferIgnoredDestinations.isEmpty)

        _ = ManagedSSHOfferPolicy.addIgnoredDestination("staging", to: &config)
        _ = ManagedSSHOfferPolicy.addIgnoredDestination("build-box", to: &config)
        #expect(config.managedSSHOfferIgnoredDestinations.contains("build-box"))
        #expect(config.managedSSHAlwaysManaged["build-box"] == nil)
    }

    @Test("re-adding to the ignored list repairs a stale always overlap")
    func readdingIgnoredRepairsStaleAlwaysOverlap() {
        // The always entry carries an owner on purpose: this repair is the one
        // path that silently destroys a persistence owner, and the user can
        // only have set that from a live connect prompt. With a nil owner the
        // assertions below hold whether or not an entry can carry one at all.
        var config = WorkspaceConfig(
            managedSSHOfferIgnoredDestinations: ["build-box"],
            managedSSHAlwaysManaged: [
                "build-box": ManagedSSHAlwaysManagedEntry(sessionName: "mysession")
            ]
        )

        let result = ManagedSSHOfferPolicy.addIgnoredDestination("build-box", to: &config)

        #expect(result == .duplicate)
        #expect(config.managedSSHOfferIgnoredDestinations == ["build-box"])
        #expect(config.managedSSHAlwaysManaged.isEmpty)
    }

    @Test("re-adding to the always list repairs a stale ignored overlap")
    func readdingAlwaysRepairsStaleIgnoredOverlap() {
        var config = WorkspaceConfig(
            managedSSHOfferIgnoredDestinations: ["build-box"],
            managedSSHAlwaysManaged: alwaysManaged("build-box")
        )

        let result = ManagedSSHOfferPolicy.addAlwaysManagedDestination("build-box", to: &config)

        #expect(result == .duplicate)
        #expect(Set(config.managedSSHAlwaysManaged.keys) == ["build-box"])
        #expect(config.managedSSHOfferIgnoredDestinations.isEmpty)
    }

    @Test("removing an always destination restores its offer eligibility")
    func removingAlwaysDestinationRestoresOfferEligibility() throws {
        let target = try #require(RemoteTarget(parsing: "build-box"))
        var config = WorkspaceConfig(
            managedSSHAlwaysManaged: alwaysManaged("build-box", "staging")
        )

        ManagedSSHOfferPolicy.removeAlwaysManagedDestination("build-box", from: &config)

        #expect(Set(config.managedSSHAlwaysManaged.keys) == ["staging"])
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

    @Test("a destination that was never stored is not recorded, whatever the owner")
    func unstoredDestinationIsNotRecorded() throws {
        let target = try #require(RemoteTarget(parsing: "prod"))
        let config = WorkspaceConfig()

        // The nil-owner case is the trap: written as
        // `alwaysManagedEntry(…)?.sessionName == sessionName?.rawValue` this
        // compares nil to nil and reports a save that never happened as a
        // success — for local-amx destinations, which is most of them.
        #expect(!ManagedSSHOfferPolicy.records(target: target, sessionName: nil, in: config))
    }

    @Test("recording is owner-sensitive, not just destination-sensitive")
    func recordingDistinguishesOwners() throws {
        let target = try #require(RemoteTarget(parsing: "prod"))
        let sessionName = try #require(RemoteSessionName(rawValue: "mysession"))
        var remote = WorkspaceConfig()
        _ = ManagedSSHOfferPolicy.addAlwaysManagedDestination(
            "prod",
            sessionName: sessionName,
            to: &remote
        )
        var local = WorkspaceConfig()
        _ = ManagedSSHOfferPolicy.addAlwaysManagedDestination("prod", to: &local)

        #expect(ManagedSSHOfferPolicy.records(target: target, sessionName: sessionName, in: remote))
        #expect(!ManagedSSHOfferPolicy.records(target: target, sessionName: nil, in: remote))
        #expect(ManagedSSHOfferPolicy.records(target: target, sessionName: nil, in: local))
        #expect(!ManagedSSHOfferPolicy.records(target: target, sessionName: sessionName, in: local))
    }

    @Test("a remembered owner survives the blanket always toggle being on")
    func rememberedOwnerSurvivesGlobalAlways() throws {
        // The one crossing no test made: every owner test left the blanket
        // toggle off, and every blanket-toggle test stored no entry. Hoisting
        // the global check above the entry lookup therefore reintroduced the
        // owner inversion — every remembered remote-owned destination
        // reconnecting local-amx — with all 34 tests green.
        let target = try #require(RemoteTarget(parsing: "prod"))
        let sessionName = try #require(RemoteSessionName(rawValue: "mysession"))
        var config = WorkspaceConfig()
        _ = ManagedSSHOfferPolicy.addAlwaysManagedDestination(
            "prod",
            sessionName: sessionName,
            to: &config
        )
        config.managedSSHAlwaysManageAllDestinations = true

        #expect(
            ManagedSSHOfferPolicy.decision(target: target, config: config)
                == .connectAutomatically(sessionName: sessionName)
        )
    }

    @Test("an unusable stored session name still does not outrank a blanket decline")
    func unusableStoredSessionNameYieldsToDisabledOffers() throws {
        let target = try #require(RemoteTarget(parsing: "prod"))
        let config = WorkspaceConfig(
            managedSSHOffersEnabled: false,
            managedSSHAlwaysManaged: ["prod": ManagedSSHAlwaysManagedEntry(sessionName: "-badname")]
        )

        // Asking is the right answer to a corrupt entry, but not over the top
        // of the one setting whose entire promise is that it will not ask.
        #expect(ManagedSSHOfferPolicy.decision(target: target, config: config) == .none)
    }

    @Test("a hand-written key still matches once normalized")
    func handWrittenKeyMatchesAfterNormalization() throws {
        // The negative test alone was unfalsifiable: junk keys do not equal a
        // real destination with or without normalization, so deleting the
        // read-side normalize step left it green. This is the positive
        // direction, and it is the only test that fails if that step goes.
        let target = try #require(RemoteTarget(parsing: "build-box"))
        let config = WorkspaceConfig(
            managedSSHAlwaysManaged: ["  build-box  ": ManagedSSHAlwaysManagedEntry()]
        )

        #expect(
            ManagedSSHOfferPolicy.decision(target: target, config: config)
                == .connectAutomatically(sessionName: nil)
        )
    }

    @Test("colliding keys resolve to the same owner on every evaluation")
    func collidingKeysResolveDeterministically() throws {
        // `@prod` and `prod` both normalize to `prod`. Dictionary iteration
        // order is seeded per process, so last-write-wins picked the owner by
        // coin flip across launches — measured at 10 of 12 runs one way. A
        // single evaluation passes by luck, so this loops.
        let target = try #require(RemoteTarget(parsing: "prod"))
        let config = WorkspaceConfig(
            managedSSHAlwaysManaged: [
                "prod": ManagedSSHAlwaysManagedEntry(),
                "@prod": ManagedSSHAlwaysManagedEntry(sessionName: "remote-owned"),
            ]
        )

        // The canonical key — the only form the app itself writes — wins.
        let expected = ManagedSSHOfferPolicy.OfferDecision.connectAutomatically(sessionName: nil)
        for _ in 0..<64 {
            #expect(ManagedSSHOfferPolicy.decision(target: target, config: config) == expected)
        }
    }

    @Test("re-remembering a destination with a different owner updates it")
    func readdingWithADifferentOwnerUpdatesTheEntry() throws {
        let target = try #require(RemoteTarget(parsing: "prod"))
        let sessionName = try #require(RemoteSessionName(rawValue: "mysession"))
        var config = WorkspaceConfig()
        _ = ManagedSSHOfferPolicy.addAlwaysManagedDestination("prod", to: &config)

        // Rejecting this as `.duplicate` left the stored owner unchangeable,
        // and the sheet's owner-sensitive verification then reported a save
        // failure that had not happened and dropped the user's connect.
        let result = ManagedSSHOfferPolicy.addAlwaysManagedDestination(
            "prod",
            sessionName: sessionName,
            to: &config
        )

        #expect(result == .added("prod"))
        #expect(ManagedSSHOfferPolicy.records(target: target, sessionName: sessionName, in: config))
        #expect(config.managedSSHAlwaysManaged.count == 1)
    }

    @Test("re-remembering with the same owner is still a duplicate")
    func readdingWithTheSameOwnerIsADuplicate() throws {
        let sessionName = try #require(RemoteSessionName(rawValue: "mysession"))
        var config = WorkspaceConfig()
        _ = ManagedSSHOfferPolicy.addAlwaysManagedDestination(
            "prod",
            sessionName: sessionName,
            to: &config
        )

        let result = ManagedSSHOfferPolicy.addAlwaysManagedDestination(
            "prod",
            sessionName: sessionName,
            to: &config
        )

        #expect(result == .duplicate)
    }

    @Test("removing a destination removes every key that normalizes to it")
    func removingClearsAllCollidingKeys() {
        var config = WorkspaceConfig(
            managedSSHAlwaysManaged: [
                "prod": ManagedSSHAlwaysManagedEntry(),
                "@prod": ManagedSSHAlwaysManagedEntry(sessionName: "remote-owned"),
                "keep-me": ManagedSSHAlwaysManagedEntry(),
            ]
        )

        ManagedSSHOfferPolicy.removeAlwaysManagedDestination("prod", from: &config)

        // A partial removal would leave the destination auto-connecting under
        // a key the Settings row no longer shows.
        #expect(Set(config.managedSSHAlwaysManaged.keys) == ["keep-me"])
    }

    /// Owner-free entries, for the precedence tests where the owner is not the
    /// subject. Tests that are *about* the owner build their entries inline —
    /// a defaulted owner here would let the overlap and removal cases read
    /// identically whether or not an entry can carry one at all.
    private func alwaysManaged(_ destinations: String...) -> [String: ManagedSSHAlwaysManagedEntry] {
        Dictionary(uniqueKeysWithValues: destinations.map { ($0, ManagedSSHAlwaysManagedEntry()) })
    }
}
