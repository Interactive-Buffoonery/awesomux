import AwesoMuxBridgeProtocol
import Foundation

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
        /// nil = cap disabled. Otherwise the age threshold in seconds.
        public var capThresholdSeconds: Int?
        public var now: Int

        public init(
            live: [LiveDaemon], idleByID: [TerminalSessionID: Bool],
            ownedByLivePane: Set<TerminalSessionID>, restorable: Set<TerminalSessionID>,
            owners: [TerminalSessionID: String], pinned: Set<TerminalSessionID>,
            capThresholdSeconds: Int?, now: Int
        ) {
            self.live = live; self.idleByID = idleByID
            self.ownedByLivePane = ownedByLivePane; self.restorable = restorable
            self.owners = owners; self.pinned = pinned
            self.capThresholdSeconds = capThresholdSeconds; self.now = now
        }
    }

    public static func resolve(_ inputs: Inputs) -> [DaemonRow] {
        var seen = Set<TerminalSessionID>()
        var rows: [DaemonRow] = []
        for daemon in inputs.live where seen.insert(daemon.id).inserted {
            let pinned = inputs.pinned.contains(daemon.id)
            let idle = inputs.idleByID[daemon.id] ?? false
            let activity: DaemonActivity = idle ? .idle : .busy
            let lifecycle = lifecycle(for: daemon, idle: idle, pinned: pinned, inputs: inputs)
            rows.append(DaemonRow(
                id: daemon.id, pid: daemon.pid, createdEpoch: daemon.createdEpoch,
                clients: daemon.clients, lifecycle: lifecycle, activity: activity,
                pinned: pinned, owner: inputs.owners[daemon.id]
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
