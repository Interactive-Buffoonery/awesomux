import Foundation

/// A pure, aggregated read model of a workspace leaf.
///
/// Chrome that presents or routes by leaf (INT-810 sidebar header, INT-809
/// artifact pane) joins on this one value instead of re-deriving kind,
/// capabilities, availability, and label separately and re-joining by id. It
/// carries no payload-specific data (no file URL, execution plan, session id);
/// consumers that need those read the concrete leaf.
public struct WorkspaceLeafDescriptor: Hashable, Sendable {
    public let id: WorkspaceLeafID
    public let kind: WorkspacePaneKind
    /// The user-visible label for this leaf.
    public let label: String
    public let capabilities: WorkspacePaneCapabilities
    public let availability: PaneAvailability

    // Internal init: a descriptor is only ever DERIVED from a `WorkspaceLeaf`
    // (via `WorkspaceLeaf.descriptor`), never hand-built. A public memberwise
    // init would let a caller pair `.terminal(id)` with `kind: .documentGroup`
    // and inconsistent capabilities/availability — leaking the very invariants
    // this joined read model exists to centralize.
    init(
        id: WorkspaceLeafID,
        kind: WorkspacePaneKind,
        label: String,
        capabilities: WorkspacePaneCapabilities,
        availability: PaneAvailability
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.capabilities = capabilities
        self.availability = availability
    }
}

public extension WorkspaceLeaf {
    /// The user-visible label: a terminal's title, or a document group's
    /// selected tab title (a group is never empty, so a fallback to the first
    /// tab always resolves).
    var label: String {
        switch self {
        case let .terminal(pane):
            pane.title
        case let .documentGroup(group):
            group.selectedTab?.title ?? group.tabs[0].title
        }
    }

    var descriptor: WorkspaceLeafDescriptor {
        WorkspaceLeafDescriptor(
            id: id,
            kind: kind,
            label: label,
            capabilities: capabilities,
            availability: availability
        )
    }
}

public extension TerminalPaneLayout {
    /// Descriptors for every leaf in tree order — the read model list the
    /// sidebar header and pane switchers iterate.
    var leafDescriptors: [WorkspaceLeafDescriptor] {
        leaves.map(\.descriptor)
    }
}
