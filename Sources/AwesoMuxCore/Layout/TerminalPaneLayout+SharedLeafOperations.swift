import Foundation

/// The outcome of `TerminalPaneLayout.removingLeaf`.
///
/// It exists to disambiguate the two opposite `nil` meanings the underlying
/// per-kind methods carry: `removingPane` returns `nil` for "the last terminal
/// went, close the workspace", while `removingDocumentGroup` returns `nil` for
/// "id not found, no-op". A shared remover returning a bare optional would let a
/// consumer wrongly close a workspace on a stale document-group id.
public enum LeafRemovalOutcome: Hashable, Sendable {
    /// The leaf was removed; the workspace survives with this layout.
    case removed(TerminalPaneLayout)
    /// The last terminal was removed; the caller must close the workspace.
    case closesWorkspace
    /// No leaf with that id was present; a no-op.
    case notFound
}

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
    /// Recurses the tree directly — allocation-free, like `pane(id:)` and
    /// `firstDocumentGroup` — rather than materializing `leaves` per call.
    func documentGroup(id: DocumentGroup.ID) -> DocumentGroup? {
        switch self {
        case .pane:
            return nil
        case let .documentGroup(group):
            return group.id == id ? group : nil
        case let .split(split):
            return split.first.documentGroup(id: id) ?? split.second.documentGroup(id: id)
        }
    }

    /// Remove a leaf by tagged id, applying the KIND-SPECIFIC policy and
    /// reporting the outcome unambiguously (see `LeafRemovalOutcome`):
    /// - `.terminal` enforces the root ≥1-terminal invariant (an auxiliary leaf
    ///   can never be the sole survivor); removing the last terminal yields
    ///   `.closesWorkspace`.
    /// - `.documentGroup` collapses the viewer split back to its sibling.
    /// An absent id yields `.notFound`, never a spurious close.
    func removingLeaf(_ id: WorkspaceLeafID) -> LeafRemovalOutcome {
        switch id {
        case let .terminal(paneID):
            guard contains(paneID: paneID) else { return .notFound }
            // Present terminal: `removingPane` returns nil ONLY when it was the
            // last terminal (the root guard), which means close the workspace.
            if let survived = removingPane(id: paneID) {
                return .removed(survived)
            }
            return .closesWorkspace
        case let .documentGroup(groupID):
            guard documentGroup(id: groupID) != nil else { return .notFound }
            if let survived = removingDocumentGroup(id: groupID) {
                return .removed(survived)
            }
            // Present but nothing survives: the group was the whole root (a
            // terminal-free layout, structurally invalid as a session but a
            // constructible `TerminalPaneLayout`). Removing it leaves nothing —
            // `.closesWorkspace`, never a spurious `.notFound` for a present id.
            return .closesWorkspace
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
