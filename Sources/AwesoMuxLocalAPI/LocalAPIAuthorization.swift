import Foundation

public enum LocalAPIGrantAction: String, Codable, Sendable {
    case status
}

public enum LocalAPITargetScope: Codable, Equatable, Sendable {
    case exactTarget(paneID: UUID, targetVersion: UUID)
    case persistentPanes([UUID])
    case persistentWorkspaces([UUID])

    public static func currentTarget(
        activePaneID: UUID?,
        targetVersions: [UUID: UUID]
    ) -> LocalAPITargetScope? {
        guard let activePaneID, let targetVersion = targetVersions[activePaneID] else { return nil }
        return .exactTarget(paneID: activePaneID, targetVersion: targetVersion)
    }

    public var isValid: Bool {
        switch self {
        case .exactTarget:
            true
        case .persistentPanes(let paneIDs):
            !paneIDs.isEmpty && Set(paneIDs).count == paneIDs.count
        case .persistentWorkspaces(let workspaceIDs):
            !workspaceIDs.isEmpty && Set(workspaceIDs).count == workspaceIDs.count
        }
    }

    public func allows(paneID: UUID, workspaceID: UUID, targetVersion: UUID) -> Bool {
        switch self {
        case .exactTarget(let allowedPaneID, let allowedTargetVersion):
            paneID == allowedPaneID && targetVersion == allowedTargetVersion
        case .persistentPanes(let paneIDs):
            paneIDs.contains(paneID)
        case .persistentWorkspaces(let workspaceIDs):
            workspaceIDs.contains(workspaceID)
        }
    }
}

public struct LocalAPIAuthorizationLease: Equatable, Sendable {
    public let connectionID: UUID
    public let globalRevision: UUID
    public let connectionRevision: UUID
    public let statusScope: LocalAPITargetScope
    public let contextGrant: LocalAPIContextGrant?

    public init(
        connectionID: UUID,
        globalRevision: UUID,
        connectionRevision: UUID,
        statusScope: LocalAPITargetScope,
        contextGrant: LocalAPIContextGrant? = nil
    ) {
        self.connectionID = connectionID
        self.globalRevision = globalRevision
        self.connectionRevision = connectionRevision
        self.statusScope = statusScope
        self.contextGrant = contextGrant
    }
}

public struct LocalAPIAuthorizationProvider: Sendable {
    public typealias Authorize =
        @Sendable (
            _ request: LocalAPIRequest,
            _ expectedLease: LocalAPIAuthorizationLease?
        ) -> Result<LocalAPIAuthorizationLease, LocalAPIError>
    public typealias Commit =
        @Sendable (
            _ request: LocalAPIRequest,
            _ lease: LocalAPIAuthorizationLease,
            _ body: @Sendable () throws -> Int
        ) throws -> Int

    private let authorizeRequest: Authorize
    private let commitResponse: Commit

    public init(authorize: @escaping Authorize, commit: @escaping Commit) {
        authorizeRequest = authorize
        commitResponse = commit
    }

    public func authorize(
        _ request: LocalAPIRequest,
        matching expectedLease: LocalAPIAuthorizationLease? = nil
    ) -> Result<LocalAPIAuthorizationLease, LocalAPIError> {
        authorizeRequest(request, expectedLease)
    }

    /// Use the lease returned by authorization for this unchanged request.
    /// The write path rechecks policy without repeating credential authentication.
    public func commit(
        _ request: LocalAPIRequest,
        lease: LocalAPIAuthorizationLease,
        body: @Sendable () throws -> Int
    ) throws -> Int {
        try commitResponse(request, lease, body)
    }

    public static let disabled = LocalAPIAuthorizationProvider(
        authorize: { _, _ in .failure(.accessDisabled) },
        commit: { _, _, _ in throw LocalAPIError.accessDisabled }
    )

    public static func unrestricted(scope: LocalAPITargetScope) -> LocalAPIAuthorizationProvider {
        let lease = LocalAPIAuthorizationLease(
            connectionID: UUID(),
            globalRevision: UUID(),
            connectionRevision: UUID(),
            statusScope: scope
        )
        return LocalAPIAuthorizationProvider(
            authorize: { _, expected in
                guard expected == nil || expected == lease else { return .failure(.permissionDenied) }
                return .success(lease)
            },
            commit: { _, expected, body in
                guard expected == lease else { throw LocalAPIError.permissionDenied }
                return try body()
            }
        )
    }
}

public enum LocalAPICredential {
    public static let byteCount = 32

    public static func encode(_ data: Data) -> String? {
        guard data.count == byteCount else { return nil }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ value: String) -> Data? {
        guard value.utf8.count == 43,
            value.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            })
        else { return nil }
        let base64 =
            value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        guard let data = Data(base64Encoded: base64), encode(data) == value else { return nil }
        return data
    }
}
