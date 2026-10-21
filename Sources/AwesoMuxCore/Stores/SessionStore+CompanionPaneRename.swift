import AwesoMuxLocalAPI
import Foundation

public extension SessionStore {
    /// Resolve native identities and intersect mutation and visibility scopes.
    /// Caller must hold a current Companion mutation lease for this whole call.
    func renameCompanionPane(
        workspaceID: UUID, paneID: UUID, title: String,
        statusScope: LocalAPITargetScope, renameScope: LocalAPITargetScope
    ) throws {
        localAPITracking = true
        reconcileLocalAPIAssignments()
        let version = localAPITargets[paneID]?.version
        func allows(_ scope: LocalAPITargetScope) -> Bool {
            switch scope {
            case .allWorkspaces: return true
            case .persistentPanes(let ids): return ids.contains(paneID)
            case .persistentWorkspaces(let ids): return ids.contains(workspaceID)
            case .exactTarget(let id, let expectedVersion): return id == paneID && version == expectedVersion
            }
        }
        guard allows(statusScope), allows(renameScope) else { throw LocalAPIError.permissionDenied }
        guard let workspace = session(id: workspaceID),
            let leaf = workspace.layout.leaves.first(where: { leaf in
                switch leaf {
                case .terminal(let pane): pane.id == paneID
                case .documentGroup(let group): group.id == paneID
                }
            })
        else { throw LocalAPIError.staleTarget }
        guard case .terminal = leaf else { throw LocalAPIError.nonterminalTarget }
        guard !SessionStoreText.sanitizedTitle(title).isEmpty else { throw LocalAPIError.invalidTitle }
        guard renamePane(sessionID: workspaceID, paneID: paneID, title: title) else { throw LocalAPIError.staleTarget }
    }
}
