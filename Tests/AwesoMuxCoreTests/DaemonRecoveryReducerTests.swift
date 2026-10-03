import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Daemon recovery reducer")
struct DaemonRecoveryReducerTests {
    @Test("recovers the exact daemon into its matching group")
    func matchingGroup() throws {
        let id = try #require(TerminalSessionID(rawValue: "recover-one"))
        let groupID = UUID()
        var groups = [SessionGroup(id: groupID, name: "Work", sessions: [])]
        let result = DaemonRecoveryReducer.recover(
            .init(id: id, metadata: metadata(groupID: groupID), cwd: NSHomeDirectory()),
            into: &groups
        )

        #expect(result != nil)
        #expect(groups[0].sessions[0].activePane?.terminalSessionID == id)
        #expect(
            groups[0].sessions[0].activePane?.terminalBackendMetadata.amxAttachDisposition
                == .existingOnly)
    }

    @Test("recovers without a reported cwd and refuses duplicate ownership")
    func refusesUnsafeRecovery() throws {
        let id = try #require(TerminalSessionID(rawValue: "recover-two"))
        var groups: [SessionGroup] = []
        let recovered = DaemonRecoveryReducer.recover(
            .init(id: id, metadata: metadata(groupID: nil), cwd: nil), into: &groups)
        #expect(recovered != nil)
        #expect(groups[0].sessions[0].workingDirectory == "~")
        #expect(
            DaemonRecoveryReducer.recover(
                .init(id: id, metadata: metadata(groupID: nil), cwd: NSHomeDirectory()),
                into: &groups) == nil)
    }

    @Test("existing-only recovery accepts a reported system directory")
    func acceptsReportedSystemDirectory() throws {
        let id = try #require(TerminalSessionID(rawValue: "recover-system-cwd"))
        var groups: [SessionGroup] = []

        let recovered = DaemonRecoveryReducer.recover(
            .init(id: id, metadata: metadata(groupID: nil), cwd: "/tmp"), into: &groups)

        #expect(recovered != nil)
        #expect(groups[0].sessions[0].workingDirectory == "/tmp")
        #expect(groups[0].sessions[0].activePane?.remoteWorkingDirectory == nil)
    }

    @Test(
        "remote recovery validates directory form without checking the local filesystem",
        arguments: [
            (nil as String?, "~", nil as String?),
            ("~", "~", nil),
            ("/remote/unsafe\npath", "~", nil),
            ("relative/project", "~", nil),
            ("file://[invalid/path", "~", nil),
            ("file://remote.example/project?query", "~", nil),
            ("file://remote.example/project%0Aunsafe", "~", nil),
            ("/remote-only-daemon-recovery/project", "/remote-only-daemon-recovery/project", nil),
            ("file://remote/remote-only-daemon-recovery/project", "/remote-only-daemon-recovery/project", nil),
            ("file://REMOTE.EXAMPLE/private/tmp", "/private/tmp", "/private/tmp"),
            ("file://localhost/private/tmp", "/private/tmp", nil),
            ("file://demo@remote.example/private/tmp", "/private/tmp", nil),
            ("file://remote.example:22/private/tmp", "/private/tmp", nil),
            (
                "file://remote.example/" + String(repeating: "a", count: 256 - "file://remote.example/".utf8.count),
                "/" + String(repeating: "a", count: 256 - "file://remote.example/".utf8.count), nil
            ),
        ]
    )
    func validatesRemoteDirectory(reported: String?, expected: String, trusted: String?) throws {
        let remote = try #require(RemoteTarget(user: "demo", host: "remote.example"))
        let recoveryMetadata = DaemonRecoveryMetadata(
            workspaceTitle: "Build", paneTitle: "Codex", groupID: nil,
            groupName: "Remote", groupRemote: remote, agentKind: .codex
        )
        var groups: [SessionGroup] = []

        let recovered = DaemonRecoveryReducer.recover(
            .init(id: .generate(), metadata: recoveryMetadata, cwd: reported), into: &groups)

        #expect(recovered != nil)
        let session = try #require(groups.first?.sessions.first)
        #expect(session.workingDirectory == expected)
        #expect(session.activePane?.workingDirectory == expected)
        #expect(session.activePane?.remoteWorkingDirectory == trusted)
        #expect(session.activePane?.executionPlan == .ssh(SSHExecution(target: remote)))
    }

    private func metadata(groupID: UUID?) -> DaemonRecoveryMetadata {
        DaemonRecoveryMetadata(
            workspaceTitle: "Build", paneTitle: "Codex", groupID: groupID,
            groupName: "Work", groupRemote: nil, agentKind: .codex
        )
    }
}
