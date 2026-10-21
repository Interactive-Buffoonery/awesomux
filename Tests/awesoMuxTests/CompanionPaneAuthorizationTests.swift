import AwesoMuxCompanionProtocol
import AwesoMuxLocalAPI
import AwesoMuxLocalAPIAccess
import Foundation
import Testing

@MainActor
@Suite("Companion pane list authorization")
struct CompanionPaneAuthorizationTests {
    private func request(_ operation: String = "list_panes", extra: [String: Any] = [:]) throws -> LocalAPIRequest {
        var object: [String: Any] = [
            "schemaVersion": 1, "requestID": UUID().uuidString,
            "profile": "development", "operation": operation,
        ]
        object.merge(extra) { _, new in new }
        return try LocalAPIContract.decoder().decode(LocalAPIRequest.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func companionOnlyOperationAndArguments() throws {
        #expect(LocalAPIOperation(rawValue: "list_panes") == nil)
        #expect(!LocalAPICapabilities().operations.contains("list_panes"))
        #expect(try CompanionRequestPolicy.authorizationOperation(for: request()) == .listAgents)
        for extra: [String: Any] in [
            ["limit": 1], ["cursor": "cursor"], ["paneID": UUID().uuidString], ["targetVersion": UUID().uuidString],
            ["source": "transcript"], ["credential": "bearer"],
        ] {
            #expect(throws: LocalAPIError.invalidRequest) {
                try CompanionRequestPolicy.authorizationOperation(for: request(extra: extra))
            }
        }
        #expect(throws: LocalAPIError.permissionDenied) {
            try CompanionRequestPolicy.authorizationOperation(for: request("get_agent_context"))
        }
    }

    @Test func alertPreferenceOperationsRemainUnsupported() throws {
        for operation in ["get_alert_preferences", "set_alert_preferences"] {
            #expect(LocalAPIOperation(rawValue: operation) == nil)
            #expect(throws: LocalAPIError.unsupportedOperation) {
                try CompanionRequestPolicy.authorizationOperation(for: request(operation))
            }
        }
    }

    @Test func permissionMutationRequiresOnlyItsBooleanArgument() throws {
        for value in [true, false] {
            #expect(
                try CompanionRequestPolicy.authorizationOperation(
                    for: request("set_terminal_preview", extra: ["terminalPreviewAllowed": value])) == .connectionStatus)
        }
        for extra: [String: Any] in [
            [:], ["terminalPreviewAllowed": NSNull()], ["terminalPreviewAllowed": 1], ["terminalPreviewAllowed": "true"],
            ["terminalPreviewAllowed": true, "limit": 1],
        ] {
            #expect(throws: (any Error).self) {
                try CompanionRequestPolicy.authorizationOperation(for: request("set_terminal_preview", extra: extra))
            }
        }
        #expect(throws: LocalAPIError.invalidRequest) {
            try CompanionRequestPolicy.authorizationOperation(for: request(extra: ["terminalPreviewAllowed": true]))
        }
        #expect(LocalAPIOperation(rawValue: "set_terminal_preview") == nil)
    }

    @Test func attentionRetainsCommandEventOptionWhileOtherReadsRejectIt() throws {
        for value: Any in [true, false, NSNull()] {
            #expect(
                try CompanionRequestPolicy.authorizationOperation(
                    for: request(
                        "get_attention_events", extra: ["limit": 100, "includeCommandEvents": value]
                    )) == .attentionEvents)
        }
        for operation in ["list_panes", "get_connection_status", "set_terminal_preview"] {
            var extra: [String: Any] = ["includeCommandEvents": true]
            if operation == "set_terminal_preview" { extra["terminalPreviewAllowed"] = true }
            #expect(throws: LocalAPIError.invalidRequest) {
                try CompanionRequestPolicy.authorizationOperation(
                    for: request(
                        operation, extra: extra
                    ))
            }
        }
    }

    @Test func certificateAndRevocationFenceContentWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pane-list-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = LocalAPIAccessStore(profile: "development", supportDirectoryURL: directory)
        let fingerprint = Data(repeating: 7, count: 32)
        let phone = try access.registerCompanion(phoneName: "Test", certificateFingerprint: fingerprint, transport: .lan, port: 1234)
        let authority = access.runtimeAuthority
        let operation = try CompanionRequestPolicy.authorizationOperation(for: request())
        let lease = try authority.authorizeCompanion(connectionID: phone.id, certificateFingerprint: fingerprint, operation: operation)
            .get()
        #expect(lease.statusScope == .allWorkspaces)
        #expect(lease.contextGrant == nil)
        #expect(throws: LocalAPIError.permissionDenied) {
            try authority.authorizeCompanion(
                connectionID: phone.id, certificateFingerprint: Data(repeating: 8, count: 32), operation: operation
            ).get()
        }
        #expect(try authority.commitCompanion(connectionID: phone.id, certificateFingerprint: fingerprint, lease: lease) { 1 } == 1)
        try access.revoke(connectionID: phone.id)
        #expect(throws: LocalAPIError.permissionDenied) {
            try authority.commitCompanion(connectionID: phone.id, certificateFingerprint: fingerprint, lease: lease) {
                Issue.record("Revoked phone must not receive content")
                return 1
            }
        }
    }
}
