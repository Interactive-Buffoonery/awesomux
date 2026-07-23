import AwesoMuxBridgeProtocol
import AwesoMuxCore
import DesignSystem

/// One row in the multi-pane peek card. A flat, pre-computed value so the card
/// never re-walks `session.layout` in `body`. Each field is sourced from the
/// pane's OWN agent state (post-INT-504), so a needy pane never paints its
/// calm sibling needy — the lie the pre-504 session-aggregate placeholder would
/// have shipped (538 R1).
struct PanePeekItem: Identifiable, Equatable {
    let id: TerminalPane.ID
    /// 1-based position matching the `⌘⌥1…⌘⌥9` "Focus Pane N" shortcuts and
    /// `focusPane(at:)` indexing, so the card row, the jump shortcut, and the
    /// focus reducer all agree on "which pane is third" even for nested splits
    /// whose depth-first order is not purely spatial (538 R8). Past pane 9 the
    /// number is position-only — there is no `⌘⌥10` — but the scroll cap means
    /// >9 panes is already a rare layout.
    let paneNumber: Int
    let title: String
    let agent: AwAgentIcon
    /// The pane's agent kind, spoken in the VoiceOver jump-action label so a
    /// per-pane action distinguishes Codex from Claude — matching what the
    /// tile's own `rowAccessibilityLabel` carries (the icon alone is silent).
    let agentShortName: String
    let state: AwState
    let unread: Int
    let isActive: Bool
    let remoteHost: String?

    var isRemote: Bool { remoteHost != nil }
}

extension PanePeekItem {
    /// Builds the row list in pane-tree order — the same traversal
    /// `focusPane(at:)` indexes — so row order and jump digits stay in lockstep.
    /// One `appendPanes` walk (O(panes)), NOT `paneIDs` + a `pane(id:)` re-search
    /// per id (which is O(panes²) — the exact anti-pattern `appendPanes`' own
    /// doc-comment warns against). This runs per collapsed tile per render via
    /// `peekRefreshKey`, so the walk count matters.
    static func items(for session: TerminalSession) -> [PanePeekItem] {
        var panes: [TerminalPane] = []
        session.layout.appendPanes(into: &panes)
        return panes.enumerated().map { index, pane in
            PanePeekItem(
                id: pane.id,
                paneNumber: index + 1,
                title: PaneTitleBarView.displayTitle(for: pane),
                agent: pane.agentKind.awAgentIcon,
                agentShortName: pane.agentKind.shortName,
                state: pane.effectiveChromeState.awState,
                unread: pane.unreadNotificationCount,
                isActive: pane.id == session.activePaneID,
                remoteHost: pane.remotePresentationHost
            )
        }
    }
}
