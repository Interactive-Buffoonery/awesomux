import AwesoMuxBridgeProtocol
import Foundation

/// Lifecycle of a command-bridge daemon as surfaced in the session manager.
/// Orthogonal to `DaemonActivity` and the pin flag (see `DaemonStateResolver`).
public enum DaemonLifecycle: String, Sendable, Equatable {
    case owned                // reachable from a live workspace pane
    case detachedRestorable   // reachable only from a reopen / recently-closed entry
    case abandoned            // orphan: no pane, no reopen entry; UUID-shaped, clients == 0
    case expired              // abandoned AND idle AND past the opt-in cap AND unpinned
    case inUseElsewhere       // clients > 0 but not in our reachable set (another client) — non-reapable
}

public enum DaemonActivity: String, Sendable, Equatable {
    case busy
    case idle
}

/// One daemon as shown in the session-manager surface. Derived purely by
/// `DaemonStateResolver` so the whole classification matrix is unit-testable.
public struct DaemonRow: Identifiable, Equatable, Sendable {
    public let id: TerminalSessionID
    public let pid: Int32
    public let daemonPID: Int32?
    public let createdEpoch: Int
    public let clients: Int
    public let lifecycle: DaemonLifecycle
    public let activity: DaemonActivity
    public let pinned: Bool
    public let owner: String?   // "workspace · pane", or nil for no owner
    public let label: String
    public let directory: String?
    public let groupName: String?
    public let agentKind: AgentKind?
    public let shortID: String

    public init(
        id: TerminalSessionID, pid: Int32, daemonPID: Int32? = nil,
        createdEpoch: Int, clients: Int,
        lifecycle: DaemonLifecycle, activity: DaemonActivity, pinned: Bool, owner: String?,
        label: String? = nil, directory: String? = nil, groupName: String? = nil,
        agentKind: AgentKind? = nil, shortID: String? = nil
    ) {
        self.id = id; self.pid = pid; self.daemonPID = daemonPID
        self.createdEpoch = createdEpoch; self.clients = clients
        self.lifecycle = lifecycle; self.activity = activity; self.pinned = pinned; self.owner = owner
        self.label = label ?? id.rawValue
        self.directory = directory
        self.groupName = groupName
        self.agentKind = agentKind
        self.shortID = shortID ?? "amx:\(id.rawValue.prefix(8))"
    }

    /// True when this daemon may be reaped from the panel without yanking a
    /// session out from under another process. `inUseElsewhere` is never reapable.
    public var isReapable: Bool { lifecycle != .inUseElsewhere }
}
