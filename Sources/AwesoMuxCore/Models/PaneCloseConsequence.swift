import Foundation

/// The type-aware consequence of closing a workspace leaf.
///
/// Thin by design: it does not re-decide terminal risk, it delegates to the
/// existing `QuitRiskPolicy` via `TerminalPane.isCloseRisk`. Document groups
/// (and any future read-only artifact leaf) close immediately — they own no
/// process and lose no work. A workspace close aggregates its leaves'
/// consequences (`TerminalPaneLayout.closeConsequences`).
public enum PaneCloseConsequence: Hashable, Sendable {
    /// Closes with no risk of losing work.
    case immediate
    /// A terminal close routed through the risk policy; `isCloseRisk` is true
    /// when destroying the pane would end live or daemon-backed work.
    case terminalRisk(isCloseRisk: Bool)
}

public extension WorkspaceLeaf {
    func closeConsequence(at now: Date = Date()) -> PaneCloseConsequence {
        switch self {
        case let .terminal(pane):
            .terminalRisk(isCloseRisk: pane.isCloseRisk(at: now))
        case .documentGroup:
            .immediate
        }
    }
}

public extension TerminalPaneLayout {
    /// Every leaf's close consequence in tree order — the workspace-level
    /// aggregate a whole-session close reasons over.
    func closeConsequences(at now: Date = Date()) -> [PaneCloseConsequence] {
        leaves.map { $0.closeConsequence(at: now) }
    }
}
