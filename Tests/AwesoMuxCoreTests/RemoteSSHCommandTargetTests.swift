import Testing
@testable import AwesoMuxCore

@Suite
struct RemoteSSHCommandTargetTests {
    @Test(arguments: [
        ("ssh devbox", true, "devbox" as String?),
        ("ssh alice@devbox", true, "alice@devbox"),
        ("ssh -p 2222 devbox", true, nil),
        ("ssh devbox uptime", true, nil),
        ("ssh -p 2222 -o BatchMode=yes devbox", true, nil),
        ("ssh -l alice devbox", true, nil),
        ("ssh -l alice -p 2222 devbox", true, nil),
        ("ssh -l alice -p 2222", false, nil),
        ("ssh-keygen -t ed25519", false, nil),
        ("echo ssh devbox", false, nil),
    ])
    func classifiesSSHCommand(command: String, isSSH: Bool, offer: String?) {
        #expect(RemoteSSHCommandTarget.isSSHCommand(command) == isSSH)
        #expect(RemoteSSHCommandTarget.parseManagedWorkspaceOffer(command) == offer)
    }
}
