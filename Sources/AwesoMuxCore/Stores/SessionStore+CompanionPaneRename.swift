import AwesoMuxLocalAPI
import Foundation

public extension SessionStore {
    /// Resolve native workspace and pane identities before renaming.
    /// Caller must hold a current Companion mutation lease for this whole call.
    func renameCompanionPane(
        workspaceID: UUID, paneID: UUID, title: String
    ) throws {
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
