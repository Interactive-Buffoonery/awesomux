import Foundation

/// The closed taxonomy of workspace-pane LEAF kinds.
///
/// `TerminalPaneLayout.split` is a structural node, not a kind — only the two
/// leaves are product-owned pane kinds today. This is deliberately a closed
/// enum, not a protocol or plugin registry (see AGENTS.md and
/// `docs/architecture.md` — "Typed workspace-pane model"): awesoMux ships a
/// small set of product-owned kinds, never arbitrary third-party injection.
///
/// Adding a kind (e.g. a future read-only artifact pane, INT-809) is one case
/// here; the compiler then forces the decision at every exhaustive switch that
/// consumes a kind. The exact touch-point checklist lives in
/// `docs/adr/0026-typed-workspace-pane-foundation.md`.
public enum WorkspacePaneKind: String, CaseIterable, Hashable, Sendable {
    case terminal
    case documentGroup
}

/// A durable reference to a layout leaf, tagged by kind.
///
/// The tag is load-bearing: a terminal pane's `UUID` and a document group's
/// `UUID` live in independent namespaces and could, in principle, collide.
/// Lookup APIs must always route through this tagged value and never compare a
/// bare `UUID` across kinds.
public enum WorkspaceLeafID: Hashable, Sendable {
    case terminal(TerminalPane.ID)
    case documentGroup(DocumentGroup.ID)

    public var kind: WorkspacePaneKind {
        switch self {
        case .terminal: .terminal
        case .documentGroup: .documentGroup
        }
    }
}

/// A layout leaf as a value, carrying its concrete payload.
///
/// This is the protocol-free "shared leaf" abstraction: type-aware projections
/// (capabilities, availability, restoration, close consequence, layout intent)
/// dispatch on this closed enum rather than on a `TerminalPaneLayout` case or a
/// leaf protocol. A terminal leaf and a document-group leaf therefore share one
/// set of layout operations without inheritance.
public enum WorkspaceLeaf: Hashable, Sendable {
    case terminal(TerminalPane)
    case documentGroup(DocumentGroup)

    public var id: WorkspaceLeafID {
        switch self {
        case let .terminal(pane): .terminal(pane.id)
        case let .documentGroup(group): .documentGroup(group.id)
        }
    }

    public var kind: WorkspacePaneKind {
        switch self {
        case .terminal: .terminal
        case .documentGroup: .documentGroup
        }
    }
}

public extension TerminalPaneLayout {
    /// The kind of this node when it is a leaf; `nil` for a `.split`.
    var leafKind: WorkspacePaneKind? {
        switch self {
        case .pane: .terminal
        case .documentGroup: .documentGroup
        case .split: nil
        }
    }

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
