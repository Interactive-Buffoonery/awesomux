import Foundation

/// What a workspace leaf is allowed to do, at LAYOUT granularity.
///
/// This exists so the view layer stops re-deriving pane behavior by inspecting
/// concrete leaf types (`if case .documentGroup`, `pane.executionPlan.remoteTarget
/// != nil`, `document.isReadOnlySnapshot`) at each call site. It is deliberately
/// leaf/layout-level: per-*tab* file access stays on `DocumentPane` +
/// `ExecutionContext` and is not folded in here.
///
/// Terminal capabilities reuse the existing `ExecutionContext` capability engine
/// rather than re-deciding local-vs-remote.
public struct WorkspacePaneCapabilities: Hashable, Sendable {
    /// The leaf can reach the local filesystem (a local terminal; a document
    /// group with no remote-snapshot tab).
    public let localFileAccess: Bool
    /// The leaf carries remote origin (an SSH terminal, or a document group with
    /// any read-only remote snapshot).
    public let remoteProvenance: Bool
    /// The leaf can safely receive a staged local path / terminal input. Only a
    /// local terminal qualifies; a remote terminal must never be handed a Mac
    /// filesystem path, and a document group is never an input target.
    public let safeInputTarget: Bool
    /// A "duplicate pane" action can clone this leaf. Terminals duplicate;
    /// document groups are session-transient auxiliary views and do not.
    public let duplicable: Bool
    /// A reusable layout preset (INT-757) may include this leaf. Only a local
    /// terminal qualifies: remote terminals carry host identity and document
    /// groups carry live file identity, neither of which a preset may encode.
    public let presetEligible: Bool

    public init(
        localFileAccess: Bool,
        remoteProvenance: Bool,
        safeInputTarget: Bool,
        duplicable: Bool,
        presetEligible: Bool
    ) {
        self.localFileAccess = localFileAccess
        self.remoteProvenance = remoteProvenance
        self.safeInputTarget = safeInputTarget
        self.duplicable = duplicable
        self.presetEligible = presetEligible
    }
}

public extension WorkspacePaneCapabilities {
    static func of(_ leaf: WorkspaceLeaf) -> WorkspacePaneCapabilities {
        switch leaf {
        case let .terminal(pane):
            terminal(pane)
        case let .documentGroup(group):
            documentGroup(group)
        }
    }

    static func terminal(_ pane: TerminalPane) -> WorkspacePaneCapabilities {
        let isLocal = ExecutionContext(plan: pane.executionPlan)
            .capability(.inspectLocalFilesystem).isAllowed
        return WorkspacePaneCapabilities(
            localFileAccess: isLocal,
            remoteProvenance: pane.executionPlan.remoteTarget != nil,
            safeInputTarget: isLocal,
            duplicable: true,
            // Belt-and-suspenders on the preset leak boundary: require BOTH the
            // local-filesystem capability AND no remote target. They agree today
            // (closed two-case plan), but they are independent signals guarding a
            // boundary where a leak means host identity in a shareable preset.
            presetEligible: isLocal && pane.executionPlan.remoteTarget == nil
        )
    }

    static func documentGroup(_ group: DocumentGroup) -> WorkspacePaneCapabilities {
        // Conservative fold: one remote snapshot makes the whole leaf carry
        // remote provenance and lose local-file standing.
        let anyRemote = group.tabs.contains { $0.isReadOnlySnapshot }
        return WorkspacePaneCapabilities(
            localFileAccess: !anyRemote,
            remoteProvenance: anyRemote,
            safeInputTarget: false,
            duplicable: false,
            presetEligible: false
        )
    }
}

public extension WorkspaceLeaf {
    var capabilities: WorkspacePaneCapabilities {
        .of(self)
    }
}
