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

    @Test func recognizesSimpleTarget() {
        #expect(RemoteSSHCommandTarget.isSSHCommand("ssh devbox"))
    }

    @Test func recognizesUserTarget() {
        #expect(RemoteSSHCommandTarget.isSSHCommand("ssh alice@devbox"))
    }

    @Test func skipsCommonOptions() {
        #expect(RemoteSSHCommandTarget.isSSHCommand("ssh -p 2222 -o BatchMode=yes devbox"))
    }

    @Test func recognizesLoginOptionWithTarget() {
        #expect(RemoteSSHCommandTarget.isSSHCommand("ssh -l alice devbox"))
    }

    @Test func recognizesLoginWithLaterPositionalHost() {
        #expect(RemoteSSHCommandTarget.isSSHCommand("ssh -l alice -p 2222 devbox"))
    }

    @Test func rejectsLoginWithoutPositionalHost() {
        #expect(!RemoteSSHCommandTarget.isSSHCommand("ssh -l alice -p 2222"))
    }

    @Test func ignoresNonSSHCommands() {
        #expect(!RemoteSSHCommandTarget.isSSHCommand("ssh-keygen -t ed25519"))
        #expect(!RemoteSSHCommandTarget.isSSHCommand("echo ssh devbox"))
    }
}
