import Testing
@testable import AwesoMuxCore

@Suite
struct BridgeEpochPolicyTests {

    @Test
    func noBaselineAdoptsFirstCandidate() {
        let decision = BridgeEpochPolicy.decide(current: nil, candidate: (gen: 1, token: "a"))
        #expect(decision == .adopt)
    }

    @Test
    func sameTokenEqualGenUsesExisting() {
        let decision = BridgeEpochPolicy.decide(current: (gen: 3, token: "a"), candidate: (gen: 3, token: "a"))
        #expect(decision == .useExisting)
    }

    @Test
    func sameEpochLowerGenIsIgnoredAsUseExisting() {
        // Same token at a lower gen (e.g. a duplicate/racing re-read of the
        // same publish) is not a new epoch; keep the existing baseline.
        let decision = BridgeEpochPolicy.decide(current: (gen: 5, token: "a"), candidate: (gen: 3, token: "a"))
        #expect(decision == .useExisting)
    }

    @Test
    func higherGenAdoptsRegardlessOfToken() {
        let decision = BridgeEpochPolicy.decide(current: (gen: 3, token: "a"), candidate: (gen: 4, token: "b"))
        #expect(decision == .adopt)
    }

    @Test
    func higherGenSameTokenStillUsesExisting() {
        // Shouldn't happen in practice (same token implies same gen per the
        // spec), but token identity takes priority over the gen comparison
        // defensively rather than mis-routing through the higher-gen branch.
        let decision = BridgeEpochPolicy.decide(current: (gen: 3, token: "a"), candidate: (gen: 9, token: "a"))
        #expect(decision == .useExisting)
    }

    @Test
    func differentTokenLowerGenIsEpochCandidate() {
        let decision = BridgeEpochPolicy.decide(current: (gen: 5, token: "a"), candidate: (gen: 1, token: "b"))
        #expect(decision == .epochCandidate)
    }

    @Test
    func differentTokenEqualGenIsEpochCandidate() {
        let decision = BridgeEpochPolicy.decide(current: (gen: 5, token: "a"), candidate: (gen: 5, token: "b"))
        #expect(decision == .epochCandidate)
    }

    @Test
    func epochCandidateCommittedOnCompletedHandshake() {
        let resolved = BridgeEpochPolicy.resolveEpochCandidate(handshakeSucceeded: true)
        #expect(resolved == .adopt)
    }

    @Test
    func epochCandidateIgnoredOnFailedHandshake() {
        let resolved = BridgeEpochPolicy.resolveEpochCandidate(handshakeSucceeded: false)
        #expect(resolved == .ignore)
    }
}
