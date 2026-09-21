import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Daemon recovery metadata")
struct DaemonRecoveryMetadataTests {
    private let remote = RemoteTarget(user: "eD", host: "dev.example")!
    private let groupID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    @Test("all fields round-trip through deterministic URL-safe labels")
    func roundTrip() {
        let metadata = DaemonRecoveryMetadata(
            workspaceTitle: "Workspace Name",
            paneTitle: "Build 🧪",
            groupID: groupID,
            groupName: "Client Work",
            groupRemote: remote,
            agentKind: .codex
        )

        let labels = metadata.encodedLabelAssignments
        #expect(labels["awesomux.workspace-title"] == "V29ya3NwYWNlIE5hbWU")
        #expect(labels.values.allSatisfy { !$0.contains("+") && !$0.contains("/") && !$0.contains("=") })
        #expect(DaemonRecoveryMetadata.decode(fields: labels) == metadata)
        #expect(metadata.encodedLabelAssignments == labels)
    }

    @Test("absent and empty values encode as removal tombstones")
    func tombstones() {
        let metadata = DaemonRecoveryMetadata(
            workspaceTitle: "",
            paneTitle: nil,
            groupID: nil,
            groupName: nil,
            groupRemote: nil,
            agentKind: nil
        )

        #expect(
            metadata.encodedLabelAssignments == [
                "awesomux.workspace-title": "",
                "awesomux.pane-title": "",
                "awesomux.group-id": "",
                "awesomux.group-name": "",
                "awesomux.group-remote": "",
                "awesomux.agent-kind": "",
            ])
        #expect(DaemonRecoveryMetadata.decode(fields: metadata.encodedLabelAssignments) == metadata)
    }

    @Test("one malformed or oversized field does not discard valid neighbors")
    func malformedFieldsAreIndependent() {
        let valid = DaemonRecoveryMetadata(
            workspaceTitle: "Valid",
            paneTitle: "Pane",
            groupID: groupID,
            groupName: nil,
            groupRemote: nil,
            agentKind: .pi
        ).encodedLabelAssignments
        var fields = valid
        fields["awesomux.pane-title"] = "not+base64"
        fields["awesomux.group-name"] = Data(
            repeating: 65,
            count: DaemonRecoveryMetadata.maximumDecodedFieldBytes + 1
        ).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let decoded = DaemonRecoveryMetadata.decode(fields: fields)
        #expect(decoded.workspaceTitle == "Valid")
        #expect(decoded.paneTitle == nil)
        #expect(decoded.groupID == groupID)
        #expect(decoded.groupName == nil)
        #expect(decoded.agentKind == .pi)
    }
}
