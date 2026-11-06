import AwesoMuxCore
import AwesoMuxLocalAPI
import AwesoMuxLocalAPIAccess
import Foundation

struct CompanionPaneRenameRequest: Decodable, Sendable {
    let workspaceID: UUID
    let paneID: UUID
    let title: String

    private struct Envelope: Decodable {
        let schemaVersion: Int
        let requestID: UUID
        let operation: String
        let connectionID: UUID
        let profile: String?
    }

    static func decode(_ object: [String: Any]) throws -> Self {
        let required: Set<String> = ["schemaVersion", "requestID", "operation", "connectionID", "workspaceID", "paneID", "title"]
        guard Set(object.keys).subtracting(["profile"]) == required,
            object["profile"] == nil || object["profile"] is String,
            let data = try? JSONSerialization.data(withJSONObject: object),
            let envelope = try? LocalAPIContract.decoder().decode(Envelope.self, from: data),
            envelope.operation == CompanionPaneRename.operation,
            let request = try? LocalAPIContract.decoder().decode(Self.self, from: data)
        else { throw LocalAPIError.invalidRequest }
        guard envelope.schemaVersion == LocalAPIContract.version else { throw LocalAPIError.unsupportedVersion }
        return request
    }
}

@MainActor
enum CompanionPaneRename {
    nonisolated static let operation = "rename_pane"

    static func apply(
        request: CompanionPaneRenameRequest,
        store: SessionStore,
        authority: LocalAPIRuntimeAuthority,
        certificateFingerprint: Data,
        lease: LocalAPIAuthorizationLease,
        deadline: ContinuousClock.Instant
    ) throws {
        try authority.performCompanionPaneRename(certificateFingerprint: certificateFingerprint, lease: lease) {
            guard !Task.isCancelled else { throw LocalAPIError.cancelled }
            guard ContinuousClock.now < deadline else { throw LocalAPIError.timeout }
            try store.renameCompanionPane(
                workspaceID: request.workspaceID, paneID: request.paneID, title: request.title)
        }
    }
}
