import AwesoMuxCompanionProtocol
import Foundation

/// Companion-only operations reuse the paired certificate's status grant;
/// they are never added to the bearer API's operation catalog.
public enum CompanionRequestPolicy {
    public static func authorizationOperation(for request: LocalAPIRequest) throws -> LocalAPIOperation {
        guard let operation = CompanionOperation(rawValue: request.operation) else {
            throw LocalAPIOperation(rawValue: request.operation) == nil
                ? LocalAPIError.unsupportedOperation : LocalAPIError.permissionDenied
        }
        guard request.credential == nil, request.paneID == nil,
            request.targetVersion == nil, request.source == nil
        else { throw LocalAPIError.invalidRequest }
        if operation == .setTerminalPreview {
            guard request.terminalPreviewAllowed != nil else { throw LocalAPIError.invalidRequest }
        } else {
            guard request.terminalPreviewAllowed == nil else { throw LocalAPIError.invalidRequest }
        }
        if operation == .attentionEvents {
            guard let limit = request.limit, limit > 0, limit <= LocalAPIContract.maximumAttentionPageSize,
                request.cursor.map({ !$0.isEmpty && $0.utf8.count <= 2048 }) ?? true
            else { throw LocalAPIError.invalidRequest }
        } else {
            guard request.includeCommandEvents == nil else { throw LocalAPIError.invalidRequest }
            guard request.limit == nil, request.cursor == nil else { throw LocalAPIError.invalidRequest }
        }
        switch operation {
        case .connectionStatus, .unpair, .setTerminalPreview: return .connectionStatus
        case .listAgents, .listPanes: return .listAgents
        case .attentionEvents: return .attentionEvents
        case .pendingDecisions, .answerDecision: throw LocalAPIError.permissionDenied
        case .getAlertPreferences, .setAlertPreferences: throw LocalAPIError.unsupportedOperation
        }
    }
}
