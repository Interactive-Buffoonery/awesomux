import Foundation

/// One shared set of layout operations over both leaf kinds, keyed on the tagged
/// `WorkspaceLeafID`.
///
/// These DISPATCH to the existing kind-specific policy methods rather than
/// flattening them into a single kind-agnostic algorithm: terminal removal and
/// document-group removal enforce genuinely different invariants (only terminal
/// removal defends the root "≥1 terminal" rule), so a unified remover could not
/// encode both safely. The shared surface is the API and the traversal, not the
/// policy.
public extension TerminalPaneLayout {
    /// Every leaf's tagged id in tree order.
    var leafIDs: [WorkspaceLeafID] {
        leaves.map(\.id)
    }

    /// The leaf value for a tagged id, or `nil` when absent. The kind tag is
    /// honored: a terminal id never resolves a document group and vice versa.
    func leaf(_ id: WorkspaceLeafID) -> WorkspaceLeaf? {
        switch id {
        case let .terminal(paneID):
            pane(id: paneID).map(WorkspaceLeaf.terminal)
        case let .documentGroup(groupID):
            documentGroup(id: groupID).map(WorkspaceLeaf.documentGroup)
        }
    }

    /// Look up a document group by id (mirrors `pane(id:)` for the other kind).
    func documentGroup(id: DocumentGroup.ID) -> DocumentGroup? {
        for leaf in leaves {
            if case let .documentGroup(group) = leaf, group.id == id {
                return group
            }
        }
        return nil
    }

    /// Remove a leaf by tagged id, applying the KIND-SPECIFIC policy:
    /// - `.terminal` enforces the root ≥1-terminal invariant (an auxiliary leaf
    ///   can never be the sole survivor); returns `nil` when the last terminal
    ///   would go, so the caller closes the session.
    /// - `.documentGroup` collapses the viewer split back to its sibling.
    func removingLeaf(_ id: WorkspaceLeafID) -> TerminalPaneLayout? {
        switch id {
        case let .terminal(paneID):
            removingPane(id: paneID)
        case let .documentGroup(groupID):
            removingDocumentGroup(id: groupID)
        }
    }

    /// Replace a leaf in place with a same-kind replacement. Cross-kind
    /// replacement is rejected (`nil`): a terminal slot cannot become a document
    /// slot without a structural move, and the tagged namespaces never mix.
    func replacingLeaf(_ id: WorkspaceLeafID, with replacement: WorkspaceLeaf) -> TerminalPaneLayout? {
        switch (id, replacement) {
        case let (.terminal(paneID), .terminal(pane)):
            replacingPane(id: paneID, with: .pane(pane))
        case let (.documentGroup(groupID), .documentGroup(group)):
            replacingDocumentGroup(id: groupID, with: group)
        case (.terminal, .documentGroup), (.documentGroup, .terminal):
            nil
        }
    }
}
