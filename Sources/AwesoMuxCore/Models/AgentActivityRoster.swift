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

    public enum Section: Int, CaseIterable, Hashable, Sendable {
        case needsYou, working, settled

        public var label: String {
            switch self {
            case .needsYou: String(localized: "Needs You", comment: "Actionable agents section")
            case .working: String(localized: "Working", comment: "Active agents section")
            case .settled: String(localized: "Settled", comment: "Inactive agents section; not proof of success")
            }
        }
    }

    public struct Row: Equatable, Sendable {
        public let sessionID: TerminalSession.ID
        public let paneID: UUID
        public let agentKind: AgentKind
        public let state: AgentDisplayState
        public let executionState: AgentExecutionState
        public let attentionReason: AttentionReason?
        public let unread: Int
        public let hasUnansweredTurn: Bool

        public var canMarkSeen: Bool {
            unread > 0 || hasUnansweredTurn || (attentionReason != nil && attentionReason?.awaitsExplicitAnswer != true)
        }

        public var section: Section {
            if AgentActivityRoster.needsAttention(state: state, execution: executionState, reason: attentionReason) {
                return .needsYou
            }
            switch executionState {
            case .running, .thinking, .output: return .working
            case .idle, .waiting, .done, .error: return .settled
            }
        }

        public var detail: String {
            if attentionReason == .permissionPrompt {
                return String(localized: "Permission requested", comment: "Agent attention reason")
            }
            // Generic provider notifications also use userInputRequired; they do not prove a question.
            if attentionReason == .processError && (state == .needsAttention || executionState == .error) {
                return String(localized: "Failed", comment: "Agent attention reason")
            }
            if executionState == .error {
                return AgentDisplayState.error.label
            }
            if section == .needsYou {
                return String(localized: "Needs your attention", comment: "Unknown agent attention reason")
            }
            if executionState == .done {
                return unread > 0
                    ? String(localized: "Finished — unread", comment: "Completed agent with unread output")
                    : String(localized: "Finished", comment: "Agent execution completed; not a review verdict")
            }
            if hasUnansweredTurn && executionState == .waiting {
                return String(localized: "Waiting — turn to review", comment: "Nonblocking finished turn, not a human permission request")
            }
            return AgentDisplayState(executionState: executionState).label
        }
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
    public let rows: [Row]

    public func nextNeedingAttention(after paneID: UUID?, orderedPaneIDs: [UUID]) -> Row? {
        let candidates = orderedRows(orderedPaneIDs: orderedPaneIDs).filter { $0.section == .needsYou }
        guard !candidates.isEmpty else { return nil }
        guard let paneID, let current = candidates.firstIndex(where: { $0.paneID == paneID }) else {
            return candidates.first
        }
        return candidates[(current + 1) % candidates.count]
    }

    public func orderedRows(orderedPaneIDs: [UUID]) -> [Row] {
        let rank = Dictionary(orderedPaneIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return rows.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element.paneID] ?? Int.max
            let right = rank[rhs.element.paneID] ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    /// Queue membership only: preserve traversal order without building display groups or sorting.
    public static func actionablePaneIDs(sessions: [TerminalSession]) -> [UUID] {
        sessions.flatMap { session in
            session.panes.compactMap { pane in
                guard pane.agentKind != .shell || pane.attentionReason?.awaitsExplicitAnswer == true else { return nil }
                return needsAttention(state: pane.effectiveChromeState, execution: pane.agentExecutionState, reason: pane.attentionReason)
                    ? pane.id : nil
            }
        }
    }

    private static func needsAttention(state: AgentDisplayState, execution: AgentExecutionState, reason: AttentionReason?) -> Bool {
        reason?.awaitsExplicitAnswer == true || state == .needsAttention || execution == .error
    }

    public static func build(_ sessions: [SessionPanes], unansweredTurnPaneIDs: Set<UUID> = [], includingShells: Bool = false)
        -> AgentActivityRoster
    {
        let rows: [Row] = sessions.flatMap { session in
            session.panes
                .filter { includingShells || $0.agentKind != .shell || $0.attentionReason?.awaitsExplicitAnswer == true }
                .map {
                    Row(
                        sessionID: session.sessionID,
                        paneID: $0.paneID,
                        agentKind: $0.agentKind,
                        state: $0.state,
                        executionState: $0.executionState,
                        attentionReason: $0.attentionReason,
                        unread: $0.unread,
                        hasUnansweredTurn: unansweredTurnPaneIDs.contains($0.paneID)
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
            total: rows.count,
            rows: rows
        )
    }
}

public extension AgentActivityRoster {
    /// App-layer entry: folds live sessions into the roster. Kept in Core so
    /// `TerminalPane.agentSnapshot` stays internal; tests use the pure
    /// `build(_:)` above with hand-built snapshots.
    static func build(sessions: [TerminalSession], unansweredTurnPaneIDs: Set<UUID> = [], includingShells: Bool = false)
        -> AgentActivityRoster
    {
        build(
            sessions.map { session in
                SessionPanes(
                    sessionID: session.id,
                    panes: session.panes.map { $0.agentSnapshot() }
                )
            }, unansweredTurnPaneIDs: unansweredTurnPaneIDs, includingShells: includingShells)
    }
}
