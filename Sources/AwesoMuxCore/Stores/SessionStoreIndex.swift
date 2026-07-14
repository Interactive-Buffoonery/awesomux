import Foundation

struct SessionStoreIndex: Sendable {
    struct Position: Hashable, Sendable {
        var groupIndex: Int
        var sessionIndex: Int
    }

    var positionsBySessionID: [TerminalSession.ID: Position]
    var unreadNotificationTotal: Int
    var livePaneIDs: Set<TerminalPane.ID>
    var remotePaneIDs: Set<TerminalPane.ID>
    /// Sessions with >=1 pane whose quit-risk does not depend on `now` (INT-420).
    /// Disjoint from `freshnessCandidateSessionIDs` by construction.
    var durableAtRiskSessionIDs: Set<TerminalSession.ID>
    /// Sessions with >=1 pane eligible for a live freshness check (non-shell agent
    /// mid-execution, no durable-risk signal) — membership does NOT mean currently
    /// at risk, only that a `now`-dependent check is needed at read time (INT-420).
    var freshnessCandidateSessionIDs: Set<TerminalSession.ID>

    /// Session-level quit-risk classification (INT-420). Mirrors `QuitRiskPolicy`'s
    /// branching but folds across a session's panes into one of three buckets so
    /// the derived counts can be cached instead of rescanned on every read.
    enum SessionRiskClass {
        case durable
        case freshnessCandidate
        case safe
    }

    static func classifySessionRisk(_ session: TerminalSession) -> SessionRiskClass {
        var hasFreshnessCandidate = false
        for pane in session.panes {
            switch pane.foregroundProcessLiveness {
            case .bridged, .exited:
                continue
            default:
                break
            }
            if pane.terminalPromptObserved && pane.needsTerminalQuitConfirmation {
                return .durable
            }
            switch pane.foregroundProcessLiveness {
            case .busyShell, .liveCommand, .indeterminate:
                return .durable
            case .idleShell, .unsampled:
                if pane.agentKind != .shell,
                   [.running, .thinking, .output].contains(pane.agentExecutionState) {
                    hasFreshnessCandidate = true
                }
            default:
                break
            }
        }
        return hasFreshnessCandidate ? .freshnessCandidate : .safe
    }

    static let empty = SessionStoreIndex(
        positionsBySessionID: [:],
        unreadNotificationTotal: 0,
        livePaneIDs: [],
        remotePaneIDs: [],
        durableAtRiskSessionIDs: [],
        freshnessCandidateSessionIDs: []
    )

    static func build(from groups: [SessionGroup]) -> SessionStoreIndex {
        var positionsBySessionID: [TerminalSession.ID: Position] = [:]
        var livePaneIDs = Set<TerminalPane.ID>()
        var remotePaneIDs = Set<TerminalPane.ID>()
        var durableAtRiskSessionIDs = Set<TerminalSession.ID>()
        var freshnessCandidateSessionIDs = Set<TerminalSession.ID>()

        for groupIndex in groups.indices {
            for sessionIndex in groups[groupIndex].sessions.indices {
                let session = groups[groupIndex].sessions[sessionIndex]
                if positionsBySessionID[session.id] == nil {
                    positionsBySessionID[session.id] = Position(
                        groupIndex: groupIndex,
                        sessionIndex: sessionIndex
                    )
                }
                livePaneIDs.formUnion(session.layout.paneIDs)
                session.layout.appendRemotePaneIDs(into: &remotePaneIDs)

                switch classifySessionRisk(session) {
                case .durable:
                    durableAtRiskSessionIDs.insert(session.id)
                case .freshnessCandidate:
                    freshnessCandidateSessionIDs.insert(session.id)
                case .safe:
                    break
                }
            }
        }

        let unreadNotificationTotal = positionsBySessionID.values.reduce(0) { total, position in
            total + groups[position.groupIndex].sessions[position.sessionIndex].unreadNotificationCount
        }

        return SessionStoreIndex(
            positionsBySessionID: positionsBySessionID,
            unreadNotificationTotal: unreadNotificationTotal,
            livePaneIDs: livePaneIDs,
            remotePaneIDs: remotePaneIDs,
            durableAtRiskSessionIDs: durableAtRiskSessionIDs,
            freshnessCandidateSessionIDs: freshnessCandidateSessionIDs
        )
    }
}
