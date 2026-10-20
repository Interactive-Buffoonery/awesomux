import AwesoMuxCompanionProtocol
import Foundation

extension LocalAPIResponse {
    public var companionResponse: CompanionAPIResponse {
        CompanionAPIResponse(
            schemaVersion: schemaVersion,
            requestID: requestID, error: error?.rawValue, profile: profile,
            appInstanceID: appInstanceID, capturedAt: capturedAt,
            connectionStatus: connectionStatus?.rawValue,
            agents: agents?.map { agent in
                CompanionAPIResponse.Agent(
                    paneID: agent.paneID.uuidString, workspaceID: agent.workspaceID.uuidString,
                    workspaceName: agent.workspaceName, provider: agent.provider,
                    executionLocation: agent.executionLocation, availability: agent.availability,
                    state: agent.state, attentionReason: agent.attentionReason, observedAt: agent.observedAt,
                    unreadCount: agent.unreadCount, stateProvenance: agent.stateProvenance,
                    capturedAt: agent.capturedAt, targetVersion: agent.targetVersion.uuidString,
                    identityEvidence: agent.identityEvidence, providerSessionID: agent.providerSessionID,
                    capabilities: agent.capabilities
                )
            },
            attentionEvents: attentionEvents.map { page in
                CompanionAPIResponse.AttentionPage(
                    events: page.events.map { event in
                        CompanionAPIResponse.Event(
                            id: event.id.uuidString, attentionID: event.attentionID.uuidString,
                            change: event.change.rawValue, paneID: event.paneID.uuidString,
                            workspaceID: event.workspaceID.uuidString, provider: event.provider,
                            occurredAt: event.occurredAt, reason: event.reason,
                            providerSessionID: event.providerSessionID, targetVersion: event.targetVersion.uuidString,
                            resolvedAt: event.resolvedAt,
                            exitCode: event.exitCode, durationSeconds: event.durationSeconds
                        )
                    },
                    nextCursor: page.nextCursor, cursorStatus: page.cursorStatus.rawValue,
                    hasMore: page.hasMore, currentStateRecoveryRequired: page.currentStateRecoveryRequired
                )
            }
        )
    }
}
