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

    @Test("refuses duplicate ownership and ambiguous unlabeled recovery")
    func refusesUnsafeRecovery() throws {
        let id = try #require(TerminalSessionID(rawValue: "recover-two"))
        var groups: [SessionGroup] = []
        #expect(
            DaemonRecoveryReducer.recover(
                .init(id: id, metadata: metadata(groupID: nil), cwd: nil), into: &groups) == nil)
        _ = DaemonRecoveryReducer.recover(
            .init(id: id, metadata: metadata(groupID: nil), cwd: NSHomeDirectory()), into: &groups)
        #expect(
            DaemonRecoveryReducer.recover(
                .init(id: id, metadata: metadata(groupID: nil), cwd: NSHomeDirectory()),
                into: &groups) == nil)
    }

    private func metadata(groupID: UUID?) -> DaemonRecoveryMetadata {
        DaemonRecoveryMetadata(
            workspaceTitle: "Build", paneTitle: "Codex", groupID: groupID,
            groupName: "Work", groupRemote: nil, agentKind: .codex
        )
    }
}
