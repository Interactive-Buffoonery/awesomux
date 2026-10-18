import Foundation

/// A workspace layout leaf carrying its concrete payload.
public enum WorkspaceLeaf: Hashable, Sendable {
    case terminal(TerminalPane)
    case documentGroup(DocumentGroup)
}

public extension TerminalPaneLayout {
    /// All leaves in tree order. The shared traversal every leaf-generic
    /// projection reuses, so a new kind never needs a bespoke walk.
    var leaves: [WorkspaceLeaf] {
        var result: [WorkspaceLeaf] = []
        appendLeaves(into: &result)
        return result
    }

    private func appendLeaves(into result: inout [WorkspaceLeaf]) {
        switch self {
        case let .pane(pane):
            result.append(.terminal(pane))
        case let .documentGroup(group):
            result.append(.documentGroup(group))
        case let .split(split):
            split.first.appendLeaves(into: &result)
            split.second.appendLeaves(into: &result)
        }
    }
}
