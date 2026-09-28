import AwesoMuxBridgeProtocol
import Foundation

public struct DaemonPresentation: Equatable, Sendable {
    public let label: String?
    public let directory: String?
    public let groupName: String?
    public let agentKind: AgentKind?
    public let owner: String?

    public init(
        label: String? = nil,
        directory: String? = nil,
        groupName: String? = nil,
        agentKind: AgentKind? = nil,
        owner: String? = nil
    ) {
        self.label = label
        self.directory = directory
        self.groupName = groupName
        self.agentKind = agentKind
        self.owner = owner
    }
}

public enum DaemonPresentationProjector {
    public static func live(groups: [SessionGroup]) -> [TerminalSessionID: DaemonPresentation] {
        var seen = Set<TerminalSessionID>()
        let candidates = groups.flatMap { group in
            group.sessions.flatMap { session in
                session.panes.map { pane in
                    (pane, session.title, group.name)
                }
            }
        }.filter { seen.insert($0.0.terminalSessionID).inserted }
        let titleCounts = Dictionary(grouping: candidates, by: { $0.1 }).mapValues(\.count)
        return Dictionary(
            uniqueKeysWithValues: candidates.map { pane, title, groupName in
                let label = titleCounts[title, default: 0] > 1 ? "\(title) · \(pane.title)" : title
                return (
                    pane.terminalSessionID,
                    DaemonPresentation(
                        label: label,
                        directory: pane.workingDirectory,
                        groupName: groupName,
                        agentKind: pane.agentKind,
                        owner: "\(title) · \(pane.title)"
                    )
                )
            })
    }

    public static func snapshots(
        recentlyClosed: [RecentlyClosedWorkspace],
        lastClosedTransient: RecentlyClosedWorkspace?
    ) -> [TerminalSessionID: DaemonPresentation] {
        var entries = recentlyClosed
        if let lastClosedTransient {
            entries.removeAll { $0.sessionID == lastClosedTransient.sessionID }
            entries.insert(lastClosedTransient, at: 0)
        }
        let candidates = entries.flatMap { entry in
            var panes: [TerminalPane] = []
            entry.layout.forEachPane { panes.append($0) }
            return panes.map { pane in
                (pane, entry.localizedTitle(), entry.groupName, entry.agentKind)
            }
        }
        let titleCounts = Dictionary(grouping: candidates, by: { $0.1 }).mapValues(\.count)
        var presentations: [TerminalSessionID: DaemonPresentation] = [:]
        for (pane, title, groupName, agentKind) in candidates where presentations[pane.terminalSessionID] == nil {
            let label = titleCounts[title, default: 0] > 1 ? "\(title) · \(pane.title)" : title
            presentations[pane.terminalSessionID] = DaemonPresentation(
                label: label,
                directory: pane.workingDirectory,
                groupName: groupName,
                agentKind: pane.agentKind == .shell ? agentKind : pane.agentKind
            )
        }
        return presentations
    }
}

/// Pure derivation of session-manager rows from a daemon list + the facts the
/// app gathers around it. Lifecycle × activity × pin are orthogonal axes (see
/// the design spec §4); keeping this pure makes the whole matrix unit-testable,
/// like `DaemonGCPlan`.
public enum DaemonStateResolver {
    public struct Inputs {
        public var live: [LiveDaemon]
        public var idleByID: [TerminalSessionID: Bool]
        public var ownedByLivePane: Set<TerminalSessionID>
        public var restorable: Set<TerminalSessionID>
        public var owners: [TerminalSessionID: String]
        public var pinned: Set<TerminalSessionID>
        public var livePresentation: [TerminalSessionID: DaemonPresentation]
        public var snapshotPresentation: [TerminalSessionID: DaemonPresentation]
        /// nil = cap disabled. Otherwise the age threshold in seconds.
        public var capThresholdSeconds: Int?
        public var now: Int

        public init(
            live: [LiveDaemon], idleByID: [TerminalSessionID: Bool],
            ownedByLivePane: Set<TerminalSessionID>, restorable: Set<TerminalSessionID>,
            owners: [TerminalSessionID: String], pinned: Set<TerminalSessionID>,
            livePresentation: [TerminalSessionID: DaemonPresentation] = [:],
            snapshotPresentation: [TerminalSessionID: DaemonPresentation] = [:],
            capThresholdSeconds: Int?, now: Int
        ) {
            self.live = live; self.idleByID = idleByID
            self.ownedByLivePane = ownedByLivePane; self.restorable = restorable
            self.owners = owners; self.pinned = pinned
            self.livePresentation = livePresentation
            self.snapshotPresentation = snapshotPresentation
            self.capThresholdSeconds = capThresholdSeconds; self.now = now
        }
    }

    public static func resolve(_ inputs: Inputs) -> [DaemonRow] {
        var seen = Set<TerminalSessionID>()
        var rows: [DaemonRow] = []
        var counted = Set<TerminalSessionID>()
        let daemonOnlyTitles: [String] = inputs.live.compactMap { daemon in
            guard counted.insert(daemon.id).inserted else { return nil }
            guard inputs.livePresentation[daemon.id] == nil,
                inputs.snapshotPresentation[daemon.id] == nil
            else { return nil }
            return daemon.recoveryMetadata?.workspaceTitle
        }
        let daemonOnlyTitleCounts = Dictionary(grouping: daemonOnlyTitles, by: { $0 })
            .mapValues(\.count)
        for daemon in inputs.live where seen.insert(daemon.id).inserted {
            let pinned = inputs.pinned.contains(daemon.id)
            let idle = inputs.idleByID[daemon.id] ?? false
            let activity: DaemonActivity = idle ? .idle : .busy
            let lifecycle = lifecycle(for: daemon, idle: idle, pinned: pinned, inputs: inputs)
            let live = inputs.livePresentation[daemon.id]
            let snapshot = inputs.snapshotPresentation[daemon.id]
            let metadata = daemon.recoveryMetadata
            let metadataLabel =
                metadata?.workspaceTitle.map { workspaceTitle in
                    if daemonOnlyTitleCounts[workspaceTitle, default: 0] > 1,
                        let paneTitle = metadata?.paneTitle
                    {
                        return "\(workspaceTitle) · \(paneTitle)"
                    }
                    return workspaceTitle
                } ?? metadata?.paneTitle
            rows.append(DaemonRow(
                    id: daemon.id, pid: daemon.pid, daemonPID: daemon.daemonPID,
                    createdEpoch: daemon.createdEpoch,
                clients: daemon.clients, lifecycle: lifecycle, activity: activity,
                    pinned: pinned,
                    owner: live?.owner ?? snapshot?.owner ?? inputs.owners[daemon.id],
                    label: live?.label ?? snapshot?.label ?? metadataLabel ?? daemon.id.rawValue,
                    directory: live?.directory ?? snapshot?.directory ?? daemon.cwd,
                    groupName: live?.groupName ?? snapshot?.groupName ?? metadata?.groupName,
                    agentKind: live?.agentKind ?? snapshot?.agentKind ?? metadata?.agentKind
            ))
        }
        return rows
    }

    private static func lifecycle(
        for daemon: LiveDaemon, idle: Bool, pinned: Bool, inputs: Inputs
    ) -> DaemonLifecycle {
        if inputs.ownedByLivePane.contains(daemon.id) { return .owned }
        if inputs.restorable.contains(daemon.id) { return .detachedRestorable }
        // Not reachable from our state. Attached by another client → never reap.
        if daemon.clients > 0 { return .inUseElsewhere }
        // Orphan (clients == 0, unreachable). Escalate to expired only when the
        // cap is on, it's currently idle, it's old enough, and it isn't pinned.
        // Ceiling: age (not idle-duration) is the cap basis — idle-duration isn't
        // tracked, so "idle now AND old" is the v1 approximation of "idle too long".
        if !pinned, let cap = inputs.capThresholdSeconds, idle,
           inputs.now - daemon.createdEpoch >= cap {
            return .expired
        }
        return .abandoned
    }
}
