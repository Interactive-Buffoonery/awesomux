import AwesoMuxBridgeProtocol
import AwesoMuxLocalAPI
import Foundation

public enum LocalAPIContextReader {
    public static func read(
        agentKind: AgentKind,
        executionPlan: PaneExecutionPlan,
        configHome: URL,
        sessionID: String?,
        limit: Int = LocalAPIContract.maximumContextBytes,
        chrome: AgentTranscriptRenderer.Chrome
    ) throws -> AgentTranscriptRenderer.Rendered {
        guard case .local = executionPlan else { throw LocalAPIError.remoteContext }
        let budget = min(max(1, limit), LocalAPIContract.maximumContextBytes)
        guard let sessionID else { throw LocalAPIError.noSessionIdentity }
        do {
            if agentKind == .openCode {
                let snapshot = try AgentTranscriptImporter.openOpenCode(
                    executionPlan: executionPlan, dataHome: configHome, reportedSessionID: sessionID
                ).get()
                return AgentTranscriptRenderer.renderOpenCodeContext(snapshot, sessionID: sessionID, chrome: chrome, budgetBytes: budget)
            }
            let transcript = try AgentTranscriptImporter.open(
                agentKind: agentKind, executionPlan: executionPlan,
                configHome: configHome, reportedSessionID: sessionID
            ).get()
            return try AgentTranscriptRenderer.renderContext(transcript, chrome: chrome, budgetBytes: budget).get()
        } catch {
            switch error {
            case .unsupportedAgent: throw LocalAPIError.unsupportedProvider
            case .remoteExecution: throw LocalAPIError.remoteContext
            case .noSessionIdentity: throw LocalAPIError.noSessionIdentity
            default: throw LocalAPIError.contextUnavailable
            }
        }
    }

    public static func boundedUTF8(_ text: String, limit: Int) -> String {
        let bytes = Array(text.utf8.prefix(limit))
        var end = bytes.count
        while end > 0 {
            if let bounded = String(bytes: bytes.prefix(end), encoding: .utf8) { return bounded }
            end -= 1
        }
        return ""
    }
}

/// The app and socket E2E host share the same permission and identity rechecks.
@MainActor
public enum LocalAPIContextCapture {
    public static func response(
        request: LocalAPIRequest,
        instanceID: UUID,
        lease: LocalAPIAuthorizationLease,
        authorization: LocalAPIAuthorizationProvider,
        sample: () async throws -> LocalAPIAgent,
        read: (LocalAPIAgent, LocalAPIContextSource, Int) async throws -> (String, Bool)
    ) async -> LocalAPIResponse {
        do {
            guard let paneID = request.paneID, let targetVersion = request.targetVersion,
                let source = request.source, let requestedLimit = request.limit, requestedLimit > 0
            else { throw LocalAPIError.invalidRequest }
            guard let grant = lease.contextGrant, grant.paneID == paneID,
                grant.targetVersion == targetVersion,
                source != .terminalHistory || grant.allowTerminalHistory
            else { throw LocalAPIError.permissionDenied }
            _ = try authorization.authorize(request, matching: lease).get()
            let agent = try await sample()
            guard agent.paneID == paneID, agent.targetVersion == targetVersion else { throw LocalAPIError.staleTarget }
            guard agent.executionLocation == "local" else { throw LocalAPIError.remoteContext }
            guard agent.identityEvidence == "local_process_incarnation" else { throw LocalAPIError.processIdentityUnknown }
            if source == .transcript, agent.providerSessionID == nil { throw LocalAPIError.noSessionIdentity }
            try Task.checkCancellation()
            _ = try authorization.authorize(request, matching: lease).get()
            let limit = min(requestedLimit, LocalAPIContract.maximumContextBytes)
            let (text, truncated) = try await read(agent, source, limit)
            try Task.checkCancellation()
            let current = try await sample()
            guard current.paneID == agent.paneID, current.targetVersion == agent.targetVersion,
                current.provider == agent.provider, current.providerSessionID == agent.providerSessionID,
                current.workspaceID == agent.workspaceID
            else { throw LocalAPIError.staleTarget }
            _ = try authorization.authorize(request, matching: lease).get()
            let content = LocalAPIContextReader.boundedUTF8(text, limit: limit)
            return LocalAPIResponse(
                requestID: request.requestID, profile: request.profile, appInstanceID: instanceID,
                capturedAt: Date(),
                agentContext: LocalAPIAgentContext(
                    agent: agent, source: source, content: content,
                    truncated: truncated || content.utf8.count < text.utf8.count
                )
            )
        } catch {
            return LocalAPIResponse(
                requestID: request.requestID,
                error: error is CancellationError ? .cancelled : (error as? LocalAPIError ?? .contextUnavailable)
            )
        }
    }
}
