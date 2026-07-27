import Testing

@testable import awesoMux

/// The close-copy suites assert through `ClosePresentationClaims`, so a wrong
/// detector makes every one of them pass for the wrong reason. These pin the
/// detectors themselves — in both directions, because a claim detector that
/// only ever returns true is indistinguishable from a working one when every
/// input happens to be a true case.
@Suite("Close presentation claim detectors")
struct ClosePresentationClaimsTests {
    @Test(
        "loss is claimed only when a negation reaches the reattach or recover verb",
        arguments: [
            // Real shipped copy — must read as loss.
            ("Closing this group closes remote panes on alice@alpha; awesoMux can't reattach them.", true),
            ("This workspace can't be reopened and cannot be recovered.", true),
            ("awesoMux will not be able to reattach this pane.", true),
            ("awesoMux is unable to reattach these panes.", true),
            ("awesoMux can no longer reattach them.", true),
            // The inversion the bare-verb match got wrong: these promise the
            // pane comes BACK, and must not read as loss.
            ("You can reattach after closing.", false),
            ("Reattach it later from Recently Closed.", false),
            ("These panes can be recovered from the remote host.", false),
            // Survival wording is not loss either.
            ("Panes on alice@alpha only disconnect; the remote host keeps their sessions running.", false),
        ])
    func lossRequiresNegation(text: String, expected: Bool) {
        #expect(
            ClosePresentationClaims.saysAwesoMuxLosesThePane(text) == expected,
            "\(expected ? "expected" : "did not expect") a loss claim in: \(text)"
        )
    }

    @Test(
        "destruction is claimed only by termination verbs",
        arguments: [
            ("The sessions awesoMux runs for it will be terminated.", true),
            ("This kills the running session.", true),
            ("Panes on alice@alpha only disconnect; the remote host keeps their sessions running.", false),
            ("awesoMux can't reattach them.", false),
        ])
    func destructionRequiresTerminationVerb(text: String, expected: Bool) {
        #expect(ClosePresentationClaims.claimsDestruction(text) == expected, "\(text)")
    }

    @Test(
        "survival is claimed only when something is said to keep running",
        arguments: [
            ("The remote host keeps their sessions running.", true),
            ("Those sessions stay running on the host.", true),
            ("The sessions awesoMux runs for it will be terminated.", false),
        ])
    func survivalRequiresKeepsRunning(text: String, expected: Bool) {
        #expect(ClosePresentationClaims.saysSomethingKeepsRunning(text) == expected, "\(text)")
    }
}
