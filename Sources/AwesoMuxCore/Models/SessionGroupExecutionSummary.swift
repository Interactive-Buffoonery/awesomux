import Foundation

/// A current, pane-derived view of where a workspace group's terminal work runs.
/// The group's SSH target remains a creation default, not runtime authority.
public struct SessionGroupExecutionSummary: Hashable, Sendable {
    public enum Contents: Hashable, Sendable {
        case empty
        case localOnly
        case singleRemote(RemoteTarget)
        case mixed(remoteTargets: [RemoteTarget], includesLocal: Bool)
    }

    public let contents: Contents
    public let defaultTarget: RemoteTarget?
    /// Destinations reached by a pane a local `amx` daemon keeps alive around
    /// its SSH child. Nothing on the far host holds that work.
    public let localAmxTargets: [RemoteTarget]
    /// Destinations named by a pane that declares remote-owned zmx persistence
    /// (ADR-0023 amendment #214). Its session lives on the far host and outlives
    /// anything awesoMux does locally. A destination can appear in both lists
    /// when its panes disagree on persistence owner.
    public let remoteOwnedTargets: [RemoteTarget]

    /// True when any pane's session lives on this Mac — a local shell, or a
    /// local `amx` daemon wrapping SSH. These are exactly the sessions a
    /// destructive close can end.
    public var includesLocallyOwnedSessions: Bool {
        if !localAmxTargets.isEmpty { return true }
        switch contents {
        case .localOnly: return true
        case .mixed(_, let includesLocal): return includesLocal
        case .empty, .singleRemote: return false
        }
    }

    public init(group: SessionGroup) {
        self.init(sessions: group.sessions, defaultTarget: group.remote)
    }

    public init(sessions: [TerminalSession], defaultTarget: RemoteTarget? = nil) {
        var includesLocal = false
        var remoteTargets = Set<RemoteTarget>()
        var localAmx = Set<RemoteTarget>()
        var remoteOwned = Set<RemoteTarget>()
        var paneCount = 0

        for session in sessions {
            session.forEachPane { pane in
                paneCount += 1
                switch pane.executionPlan.location {
                case .local:
                    includesLocal = true
                case .remote(let target):
                    remoteTargets.insert(target)
                    if pane.executionPlan.remoteOwnedExecution == nil {
                        localAmx.insert(target)
                    } else {
                        remoteOwned.insert(target)
                    }
                }
            }
        }

        let targets = remoteTargets.sorted(by: Self.targetSort)
        self.defaultTarget = defaultTarget
        self.localAmxTargets = localAmx.sorted(by: Self.targetSort)
        self.remoteOwnedTargets = remoteOwned.sorted(by: Self.targetSort)
        if paneCount == 0 {
            contents = .empty
        } else if targets.isEmpty {
            contents = .localOnly
        } else if !includesLocal, targets.count == 1 {
            contents = .singleRemote(targets[0])
        } else {
            contents = .mixed(remoteTargets: targets, includesLocal: includesLocal)
        }
    }

    private static func targetSort(_ lhs: RemoteTarget, _ rhs: RemoteTarget) -> Bool {
        if lhs.sshDestination != rhs.sshDestination {
            return lhs.sshDestination < rhs.sshDestination
        }
        if lhs.user != rhs.user { return lhs.user < rhs.user }
        return lhs.host < rhs.host
    }
}

/// Exact pane locations covered by one group-close confirmation. This stays a
/// short-lived value around the modal and is never stored on the group.
public struct SessionGroupCloseSafetySummary: Hashable, Sendable {
    public struct PaneLocation: Hashable, Sendable {
        public let sessionID: TerminalSession.ID
        public let paneID: TerminalPane.ID
        public let location: ExecutionLocation
    }

    public let defaultTarget: RemoteTarget?
    public let paneLocations: Set<PaneLocation>

    public init(group: SessionGroup, limitedTo sessionIDs: Set<TerminalSession.ID>? = nil) {
        defaultTarget = group.remote
        paneLocations = Set(
            group.sessions
                .filter { sessionIDs?.contains($0.id) ?? true }
                .flatMap { session in
                    session.panes.map { pane in
                        PaneLocation(
                            sessionID: session.id,
                            paneID: pane.id,
                            location: pane.executionPlan.location
                        )
                    }
                })
    }

    public static func hasMaterialChange(
        from confirmedGroup: SessionGroup,
        to liveGroup: SessionGroup,
        confirmedSessionIDs: Set<TerminalSession.ID>
    ) -> Bool {
        let liveConfirmedIDs = Set(liveGroup.sessions.map(\.id))
            .intersection(confirmedSessionIDs)
        return Self(group: confirmedGroup, limitedTo: liveConfirmedIDs)
            != Self(group: liveGroup, limitedTo: liveConfirmedIDs)
    }
}
