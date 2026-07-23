import AwesoMuxBridgeProtocol
import Foundation

/// The sidebar footer's agent roster (INT-722): every non-shell agent pane,
/// grouped by display state in priority order. Pure projection — built per
/// render from the same pane snapshots the session rollup folds, so the
/// panel, the footer chips, and the sidebar badge can never disagree. The view
/// rebuilds it when its session-store invalidation key changes.
public struct AgentActivityRoster: Equatable, Sendable {
    /// One session's pane snapshots — the builder's input unit. Kept as an
    /// explicit pair (not `TerminalSession`) so tests build fixtures without
    /// constructing sessions.
    public struct SessionPanes: Equatable, Sendable {
        public let sessionID: TerminalSession.ID
        public let panes: [PaneAgentSnapshot]

        public init(sessionID: TerminalSession.ID, panes: [PaneAgentSnapshot]) {
            self.sessionID = sessionID
            self.panes = panes
        }
    }

    public struct Row: Equatable, Sendable {
        public let sessionID: TerminalSession.ID
        public let paneID: UUID
        public let agentKind: AgentKind
        public let state: AgentDisplayState
    }

    public struct Group: Equatable, Sendable {
        public let state: AgentDisplayState
        public let rows: [Row]
    }

    /// Non-empty groups, ordered by `AgentDisplayState.priority` (most urgent
    /// first). Row order within a group is input traversal order — the
    /// sidebar's group/session order — so rows don't shuffle between renders.
    public let groups: [Group]
    /// Pane-grain counts per state (agent panes only) — the footer chips'
    /// numbers, derived from the same rows so chip and panel always agree.
    public let counts: [AgentDisplayState: Int]
    public let total: Int

    public static func build(_ sessions: [SessionPanes]) -> AgentActivityRoster {
        let rows: [Row] = sessions.flatMap { session in
            session.panes
                .filter { $0.agentKind != .shell }
                .map {
                    Row(
                        sessionID: session.sessionID,
                        paneID: $0.paneID,
                        agentKind: $0.agentKind,
                        state: $0.state
                    )
                }
        }
        let byState = Dictionary(grouping: rows, by: \.state)
        let groups = byState
            .sorted { $0.key.priority < $1.key.priority }
            .map { Group(state: $0.key, rows: $0.value) }
        return AgentActivityRoster(
            groups: groups,
            counts: byState.mapValues(\.count),
            total: rows.count
        )
    }
}

public extension AgentActivityRoster {
    /// App-layer entry: folds live sessions into the roster. Kept in Core so
    /// `TerminalPane.agentSnapshot` stays internal; tests use the pure
    /// `build(_:)` above with hand-built snapshots.
    static func build(sessions: [TerminalSession], at now: Date) -> AgentActivityRoster {
        build(sessions.map { session in
            SessionPanes(
                sessionID: session.id,
                panes: session.panes.map { $0.agentSnapshot(at: now) }
            )
        })
    }
}
