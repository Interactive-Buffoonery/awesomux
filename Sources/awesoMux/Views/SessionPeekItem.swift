import AwesoMuxCore
import DesignSystem

/// One row in the collapsed sidebar's group-roster peek card. A flat,
/// pre-computed value so the card never re-walks agent rollups in `body` —
/// same shape as `PanePeekItem`, one level up (session instead of pane).
struct SessionPeekItem: Identifiable, Equatable {
    let id: TerminalSession.ID
    let title: String
    let agent: AwAgentIcon
    /// The winning agent's kind, spoken in the VoiceOver jump-action label so
    /// a per-session action distinguishes Codex from Claude — matching what
    /// `PanePeekItem.agentShortName` carries one level down (the icon alone
    /// is silent).
    let agentShortName: String
    let state: AwState
    let unread: Int
    let isActive: Bool
    let locationText: String?
    let accessibilityLocationText: String
}

extension SessionPeekItem {
    /// Builds the row list in the caller's given order — callers pass the
    /// already-filtered, already-ordered list the collapsed rail is
    /// currently rendering for a group (see `SidebarGroupHeaderRow.entries`),
    /// never raw `SessionGroup.sessions` (which still includes sessions
    /// floated out to the synthetic Pinned section).
    static func items(
        for sessions: [TerminalSession],
        activeSessionID: TerminalSession.ID?
    ) -> [SessionPeekItem] {
        sessions.map { session in
            let rollup = session.agentRollup()
            let location = SessionGroupExecutionPresentation(
                summary: SessionGroupExecutionSummary(sessions: [session])
            )
            return SessionPeekItem(
                id: session.id,
                title: session.title,
                agent: rollup.winningAgentKind.awAgentIcon,
                agentShortName: rollup.winningAgentKind.shortName,
                state: rollup.state.awState,
                unread: rollup.unreadTotal,
                isActive: session.id == activeSessionID,
                locationText: location.visibleText,
                accessibilityLocationText: location.accessibilityText
            )
        }
    }
}
