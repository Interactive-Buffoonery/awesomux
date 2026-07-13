import Testing
@testable import AwesoMuxCore

@Suite
struct RemoteSSHCommandTargetTests {
    @Test func managedWorkspaceOfferAcceptsOnlySimpleDestinations() {
        #expect(RemoteSSHCommandTarget.parseManagedWorkspaceOffer("ssh devbox") == "devbox")
        #expect(RemoteSSHCommandTarget.parseManagedWorkspaceOffer("ssh alice@devbox") == "alice@devbox")
        #expect(RemoteSSHCommandTarget.parseManagedWorkspaceOffer("ssh -p 2222 devbox") == nil)
        #expect(RemoteSSHCommandTarget.parseManagedWorkspaceOffer("ssh devbox uptime") == nil)
    }

    @Test func parsesSimpleTarget() {
        #expect(RemoteSSHCommandTarget.parseSubmittedCommand("ssh devbox") == "devbox")
    }

    @Test func parsesUserTarget() {
        #expect(RemoteSSHCommandTarget.parseSubmittedCommand("ssh alice@devbox") == "alice@devbox")
    }

    @Test func skipsCommonOptions() {
        #expect(
            RemoteSSHCommandTarget.parseSubmittedCommand("ssh -p 2222 -o BatchMode=yes devbox")
                == "devbox"
        )
    }

    @Test func combinesLoginOptionWithTarget() {
        #expect(RemoteSSHCommandTarget.parseSubmittedCommand("ssh -l alice devbox") == "alice@devbox")
    }

    @Test func combinesLoginWithLaterPositionalHost() {
        #expect(
            RemoteSSHCommandTarget.parseSubmittedCommand("ssh -l alice -p 2222 devbox")
                == "alice@devbox"
        )
    }

    @Test func loginWithoutPositionalHostIsNil() {
        #expect(RemoteSSHCommandTarget.parseSubmittedCommand("ssh -l alice -p 2222") == nil)
    }

    @Test func loginOptionOverridesPositionalUser() {
        // OpenSSH lets `-l` win over a `user@` in the destination.
        #expect(RemoteSSHCommandTarget.parseSubmittedCommand("ssh -l alice bob@devbox") == "alice@devbox")
    }

    @Test func ignoresNonSSHCommands() {
        #expect(RemoteSSHCommandTarget.parseSubmittedCommand("ssh-keygen -t ed25519") == nil)
        #expect(RemoteSSHCommandTarget.parseSubmittedCommand("echo ssh devbox") == nil)
    }
}
