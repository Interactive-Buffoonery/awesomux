import Foundation
import AwesoMuxConfig
import AwesoMuxCore
import Testing
@testable import awesoMux

@MainActor
@Suite("Managed SSH workspace offer identity")
struct ManagedSSHWorkspaceOfferIdentityTests {
    @Test("only automatic offers show remember actions")
    func onlyAutomaticOffersShowRememberActions() {
        #expect(SSHWorkspaceConnectOrigin.automaticOffer.showsRememberActions)
        #expect(!SSHWorkspaceConnectOrigin.explicitConnection.showsRememberActions)
        #expect(!SSHWorkspaceConnectOrigin.explicitConversion.showsRememberActions)
    }

    @Test("an allowed automatic offer is identified and consumed once")
    func allowedAutomaticOfferIsIdentifiedAndConsumedOnce() throws {
        let (store, sessionID, paneID) = try makeObservedStore(destination: "host-a")

        let target = try #require(
            store.consumeManagedSSHWorkspaceOffer(sessionID: sessionID, paneID: paneID)
        )
        let request = SSHWorkspaceConnectRequest.automaticOffer(
            sessionID: sessionID,
            paneID: paneID,
            target: target
        )

        #expect(request.origin == .automaticOffer)
        #expect(request.initialDestination == "host-a")
        #expect(store.consumeManagedSSHWorkspaceOffer(sessionID: sessionID, paneID: paneID) == nil)
    }

    @Test("a suppressed automatic offer is consumed without presenting")
    func suppressedAutomaticOfferIsConsumedWithoutPresenting() throws {
        let (store, sessionID, paneID) = try makeObservedStore(destination: "host-a")
        let config = WorkspaceConfig(
            managedSSHOfferIgnoredDestinations: ["host-a"]
        )

        // `#require`, not a bare optional: `resolve(target: nil, …)` returns
        // `.doNothing` from its first guard, so an unwrapped optional would let
        // a store that consumed nothing pass a test named for consumption.
        let target = try #require(
            store.consumeManagedSSHWorkspaceOffer(sessionID: sessionID, paneID: paneID)
        )

        // Through the resolver the app actually uses, not a hand-rolled repeat
        // of the two calls behind it: this now fails if the suppressed arm is
        // rewired to present the sheet.
        #expect(ManagedSSHOfferEffect.resolve(target: target, config: config) == .doNothing)

        #expect(store.consumeManagedSSHWorkspaceOffer(sessionID: sessionID, paneID: paneID) == nil)
        #expect(store.managedSSHConversionTarget(sessionID: sessionID, paneID: paneID)?.sshDestination == "host-a")
    }

    @Test("a new target in the same pane gets one new automatic offer")
    func newTargetGetsOneNewOffer() throws {
        let session = TerminalSession(
            title: "shell",
            workingDirectory: NSHomeDirectory(),
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "Work", sessions: [session])],
            selectedSessionID: session.id
        )
        let paneID = try #require(session.activePane?.id)

        store.noteSubmittedCommand(sessionID: session.id, paneID: paneID, command: "ssh host-a")
        store.updatePane(sessionID: session.id, paneID: paneID, title: "alice@host-a: ~/app")
        let hostAIdentity = ManagedSSHWorkspaceOfferIdentity(
            paneID: paneID,
            sshDestination: try #require(
                store.consumeManagedSSHWorkspaceOffer(
                    sessionID: session.id,
                    paneID: paneID
                )
            ).sshDestination
        )
        #expect(store.consumeManagedSSHWorkspaceOffer(sessionID: session.id, paneID: paneID) == nil)

        store.updatePane(
            sessionID: session.id,
            paneID: paneID,
            workingDirectory: NSHomeDirectory()
        )
        store.noteSubmittedCommand(sessionID: session.id, paneID: paneID, command: "ssh host-b")
        store.updatePane(sessionID: session.id, paneID: paneID, title: "alice@host-b: ~/app")
        let hostBIdentity = ManagedSSHWorkspaceOfferIdentity(
            paneID: paneID,
            sshDestination: try #require(
                store.consumeManagedSSHWorkspaceOffer(
                    sessionID: session.id,
                    paneID: paneID
                )
            ).sshDestination
        )

        #expect(hostBIdentity != hostAIdentity)
        #expect(hostBIdentity.sshDestination == "host-b")
        #expect(store.consumeManagedSSHWorkspaceOffer(sessionID: session.id, paneID: paneID) == nil)
    }

    private func makeObservedStore(
        destination: String
    ) throws -> (SessionStore, TerminalSession.ID, TerminalPane.ID) {
        let session = TerminalSession(
            title: "shell",
            workingDirectory: NSHomeDirectory(),
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "Work", sessions: [session])],
            selectedSessionID: session.id
        )
        let paneID = try #require(session.activePane?.id)
        store.noteSubmittedCommand(sessionID: session.id, paneID: paneID, command: "ssh \(destination)")
        store.updatePane(sessionID: session.id, paneID: paneID, title: "alice@\(destination): ~/app")
        return (store, session.id, paneID)
    }
}
