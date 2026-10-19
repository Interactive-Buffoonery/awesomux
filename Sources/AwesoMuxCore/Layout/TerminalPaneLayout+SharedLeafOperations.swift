import Foundation

public extension TerminalPaneLayout {
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
}
