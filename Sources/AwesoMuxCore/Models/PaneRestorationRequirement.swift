import AwesoMuxBridgeProtocol
import Foundation

/// What reopening a captured leaf requires — the INT-425 pane-level reopen seam.
///
/// It deliberately separates REATTACHING an existing terminal (which needs the
/// durable, restore-only `TerminalSessionID` to re-bind its daemon) from
/// RECREATING a leaf from configuration. Keeping these distinct is what stops a
/// preset — which must never carry daemon identity — from consuming reopen-only
/// state: presets project through `WorkspaceLayoutIntent` (no session id),
/// reopen projects through this type (may carry one).
public enum PaneRestorationRequirement: Hashable, Sendable {
    /// Reattach to the existing daemon-backed terminal session by durable id.
    case reattachTerminal(TerminalSessionID)
    /// Reopen a document group by re-reading its tabs' file identities.
    case reopenDocumentGroup
}

public extension WorkspaceLeaf {
    var restorationRequirement: PaneRestorationRequirement {
        switch self {
        case let .terminal(pane):
            .reattachTerminal(pane.terminalSessionID)
        case .documentGroup:
            .reopenDocumentGroup
        }
    }
}
