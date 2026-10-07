import Foundation

public enum LocalAPIContract {
    public static let version = 1
    public static let maximumRequestBytes = 8 * 1024
    public static let maximumResponseBytes = 256 * 1024
    public static let timeout: TimeInterval = 5
    public static let maximumClients = 8
    public static let maximumContextBytes = 24 * 1024
    public static let maximumAttentionEvents = 512
    public static let maximumAttentionPageSize = 100

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum LocalAPIOperation: String, Codable, CaseIterable, Sendable {
    case connectionStatus = "get_connection_status"
    case capabilities = "get_capabilities"
    case listAgents = "list_agents"
    case agentContext = "get_agent_context"
    case attentionEvents = "get_attention_events"
}

public struct LocalAPIRequest: Codable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID
    public let profile: String
    public let operation: String
    public let connectionID: UUID?
    public let credential: String?
    public let paneID: UUID?
    public let targetVersion: UUID?
    public let limit: Int?
    public let source: LocalAPIContextSource?
    public let cursor: String?

    public init(
        profile: String,
        operation: LocalAPIOperation,
        connectionID: UUID? = nil,
        credential: String? = nil,
        paneID: UUID? = nil, targetVersion: UUID? = nil,
        limit: Int? = nil, source: LocalAPIContextSource? = nil, cursor: String? = nil
    ) {
        schemaVersion = LocalAPIContract.version
        requestID = UUID()
        self.profile = profile
        self.operation = operation.rawValue
        self.connectionID = connectionID
        self.credential = credential
        self.paneID = paneID
        self.targetVersion = targetVersion
        self.limit = limit
        self.source = source
        self.cursor = cursor
    }
}

public enum LocalAPIError: String, Error, Codable, Sendable {
    case invalidRequest = "invalid_request"
    case unsupportedVersion = "unsupported_version"
    case unsupportedOperation = "unsupported_operation"
    case profileMismatch = "profile_mismatch"
    case accessDisabled = "access_disabled"
    case permissionDenied = "permission_denied"
    case credentialUnavailable = "credential_unavailable"
    case appUnavailable = "app_unavailable"
    case insecureEndpoint = "insecure_endpoint"
    case endpointBusy = "endpoint_busy"
    case pathTooLong = "path_too_long"
    case requestTooLarge = "request_too_large"
    case responseTooLarge = "response_too_large"
    case timeout
    case cancelled
    case staleTarget = "stale_target"
    case transportFailure = "transport_failure"
    case contextUnavailable = "context_unavailable"
    case noSessionIdentity = "no_session_identity"
    case unsupportedProvider = "unsupported_provider"
    case remoteContext = "remote_context"
    case contextTooLarge = "context_too_large"
    case processIdentityUnknown = "process_identity_unknown"
    case invalidCursor = "invalid_cursor"
}

public struct LocalAPICapabilities: Codable, Sendable {
    public let operations: [String]
    public let maximumRequestBytes: Int
    public let maximumResponseBytes: Int
    public let timeoutSeconds: TimeInterval
    public let maximumContextBytes: Int
    public let maximumAttentionEvents: Int
    public let maximumAttentionPageSize: Int
    public let attentionEvents: Bool
    public let context: Bool
    public let instructions: Bool
    public let monitoring: Bool

    public init() {
        operations = LocalAPIOperation.allCases.map(\.rawValue)
        maximumRequestBytes = LocalAPIContract.maximumRequestBytes
        maximumResponseBytes = LocalAPIContract.maximumResponseBytes
        timeoutSeconds = LocalAPIContract.timeout
        maximumContextBytes = LocalAPIContract.maximumContextBytes
        maximumAttentionEvents = LocalAPIContract.maximumAttentionEvents
        maximumAttentionPageSize = LocalAPIContract.maximumAttentionPageSize
        attentionEvents = true
        context = true
        instructions = false
        monitoring = false
    }
}

public struct LocalAPIAgent: Codable, Sendable {
    public let paneID: UUID
    public let workspaceID: UUID
    public let workspaceName: String
    public let provider: String
    public let executionLocation: String
    public let availability: String
    public let state: String
    public let attentionReason: String?
    public let unreadCount: Int
    public let stateProvenance: String
    public let observedAt: Date?
    public let capturedAt: Date
    public let targetVersion: UUID
    public let identityEvidence: String
    public let providerSessionID: String?
    public let capabilities: [String]

    public init(
        paneID: UUID, workspaceID: UUID, workspaceName: String, provider: String,
        executionLocation: String, availability: String, state: String,
        attentionReason: String?, unreadCount: Int, stateProvenance: String,
        observedAt: Date?, capturedAt: Date, targetVersion: UUID,
        identityEvidence: String, providerSessionID: String?, capabilities: [String]
    ) {
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.provider = provider
        self.executionLocation = executionLocation
        self.availability = availability
        self.state = state
        self.attentionReason = attentionReason
        self.unreadCount = unreadCount
        self.stateProvenance = stateProvenance
        self.observedAt = observedAt
        self.capturedAt = capturedAt
        self.targetVersion = targetVersion
        self.identityEvidence = identityEvidence
        self.providerSessionID = providerSessionID
        self.capabilities = capabilities
    }
}

public enum LocalAPIConnectionStatus: String, Codable, Sendable {
    case connected
}

public struct LocalAPIResponse: Codable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID?
    public let error: LocalAPIError?
    public let profile: String?
    public let appInstanceID: UUID?
    public let capturedAt: Date?
    public let connectionStatus: LocalAPIConnectionStatus?
    public let capabilities: LocalAPICapabilities?
    public let agents: [LocalAPIAgent]?
    public let agentContext: LocalAPIAgentContext?
    public let contextGrant: LocalAPIContextGrant?
    public let attentionEvents: LocalAPIAttentionPage?

    public init(
        requestID: UUID? = nil, error: LocalAPIError? = nil, profile: String? = nil,
        appInstanceID: UUID? = nil, capturedAt: Date? = nil,
        connectionStatus: LocalAPIConnectionStatus? = nil, capabilities: LocalAPICapabilities? = nil, agents: [LocalAPIAgent]? = nil,
        agentContext: LocalAPIAgentContext? = nil, contextGrant: LocalAPIContextGrant? = nil,
        attentionEvents: LocalAPIAttentionPage? = nil
    ) {
        schemaVersion = LocalAPIContract.version
        self.requestID = requestID
        self.error = error
        self.profile = profile
        self.appInstanceID = appInstanceID
        self.capturedAt = capturedAt
        self.connectionStatus = connectionStatus
        self.capabilities = capabilities
        self.agents = agents
        self.agentContext = agentContext
        self.contextGrant = contextGrant
        self.attentionEvents = attentionEvents
    }
}

public enum LocalAPIProfile {
    public static func isValid(_ profile: String) -> Bool {
        if profile == "production" || profile == "development" { return true }
        let prefix = "development:"
        guard profile.hasPrefix(prefix) else { return false }
        let suffix = profile.dropFirst(prefix.count)
        return suffix.utf8.count == 12
            && suffix.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}
