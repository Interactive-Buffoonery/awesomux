import AwesoMuxLocalAPI
import Foundation

public struct CompanionTerminalCreated: Codable, Sendable {
    public let workspaceID: UUID
    public let paneID: UUID
    public let targetVersion: UUID
}

public extension SessionStore {
    /// Caller holds the device's Terminal and Input authority through this mutation.
    func createCompanionTerminal(workspaceID requestedWorkspaceID: UUID?, defaultGroup: String) throws -> CompanionTerminalCreated {
        let workspaceID: UUID
        let paneID: UUID
        if let existingID = requestedWorkspaceID {
            guard session(id: existingID) != nil else { throw LocalAPIError.staleTarget }
            guard let createdID = splitActivePane(orientation: .vertical, in: existingID) else {
                throw LocalAPIError.nonterminalTarget
            }
            workspaceID = existingID
            paneID = createdID
        } else {
            workspaceID = addSession(groupName: defaultGroup, executionPlan: .local)
            guard let pane = session(id: workspaceID)?.activePane else { throw LocalAPIError.staleTarget }
            paneID = pane.id
        }
        guard let target = localAPITerminalWatchTarget(paneID: paneID) else { throw LocalAPIError.staleTarget }
        return CompanionTerminalCreated(workspaceID: workspaceID, paneID: paneID, targetVersion: target.targetVersion)
    }

    func companionTerminalToOpen(paneID: UUID, targetVersion: UUID) throws -> (TerminalSession, TerminalPane, LocalAPITerminalWatchTarget) {
        guard let target = localAPITerminalWatchTarget(paneID: paneID), target.targetVersion == targetVersion,
            let workspace = session(id: target.workspaceID), let pane = workspace.layout.pane(id: paneID)
        else { throw LocalAPIError.staleTarget }
        if case .disconnected = pane.remoteReconnect { throw LocalAPIError.paneDisconnected }
        if case .reconnecting = pane.remoteReconnect { throw LocalAPIError.paneDisconnected }
        guard pane.foregroundProcessLiveness != .exited else { throw LocalAPIError.paneExited }
        guard pane.remoteConnectionHealth != .possiblyStale else { throw LocalAPIError.paneDisconnected }
        guard target.localSessionName != nil else { throw LocalAPIError.terminalUnavailable }
        return (workspace, pane, target)
    }
}
