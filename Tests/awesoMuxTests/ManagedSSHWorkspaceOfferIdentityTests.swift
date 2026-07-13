import Foundation
import AwesoMuxCore
import Testing
@testable import awesoMux

@MainActor
@Suite("Managed SSH workspace offer identity")
struct ManagedSSHWorkspaceOfferIdentityTests {
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
}
