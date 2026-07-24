import Foundation
import UnicodeHygiene

public enum PersistenceOwner: String, Codable, Hashable, Sendable {
    case localAmx
    case remoteZmx
}

/// `SSHExecution` deliberately has no `Codable` conformance: `PaneExecutionPlan`
/// flattens these fields into its own container, and a synthesized standalone
/// decoder would rebuild the struct without re-checking the invariants below.
public struct SSHExecution: Hashable, Sendable {
    public let target: RemoteTarget
    public let persistenceOwner: PersistenceOwner
    /// Nil for `.localAmx`. Names the zmx session on the remote host.
    public let sessionName: RemoteSessionName?
    /// Absolute path to `zmx` on the remote host; nil means bare `zmx` on PATH.
    public let remoteExecutablePath: String?

    public init(target: RemoteTarget) {
        self.target = target
        self.persistenceOwner = .localAmx
        self.sessionName = nil
        self.remoteExecutablePath = nil
    }

    /// Returns nil when the persistence owner and its remote fields disagree:
    /// local-amx panes carry no remote zmx identity, remote-owned panes must
    /// name their session, and an explicit executable path is only meaningful
    /// (and only accepted as an absolute, hygiene-clean path) for remote-owned
    /// panes.
    public init?(
        target: RemoteTarget,
        persistenceOwner: PersistenceOwner,
        sessionName: RemoteSessionName?,
        remoteExecutablePath: String?
    ) {
        switch persistenceOwner {
        case .localAmx:
            guard sessionName == nil, remoteExecutablePath == nil else { return nil }
        case .remoteZmx:
            guard sessionName != nil else { return nil }
        }
        if let path = remoteExecutablePath {
            guard persistenceOwner == .remoteZmx,
                path.hasPrefix("/"),
                !UnicodeHygiene.containsUnsafePathScalars(path)
            else {
                return nil
            }
        }
        self.target = target
        self.persistenceOwner = persistenceOwner
        self.sessionName = sessionName
        self.remoteExecutablePath = remoteExecutablePath
    }
}

public enum PaneExecutionPlan: Hashable, Sendable {
    case local
    case ssh(SSHExecution)

    public var location: ExecutionLocation {
        switch self {
        case .local: .local
        case .ssh(let execution): .remote(execution.target)
        }
    }

    public var remoteTarget: RemoteTarget? {
        switch self {
        case .local: nil
        case .ssh(let execution): execution.target
        }
    }

    /// The SSH execution whose session the REMOTE host owns, when this plan
    /// declares one. Nil for local panes and for local-amx SSH panes — i.e.
    /// non-nil exactly when there is no local `amx` daemon in front of the pane.
    /// Single definition so the surface-command policy, the preflight gate, and
    /// the enactor cannot drift on what "remote-owned" means.
    public var remoteOwnedExecution: SSHExecution? {
        guard case .ssh(let execution) = self, execution.persistenceOwner == .remoteZmx else {
            return nil
        }
        return execution
    }
}

extension PaneExecutionPlan: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case target
        case persistenceOwner
        case sessionName
        case remoteExecutablePath
    }

    private enum Kind: String, Codable {
        case local
        case ssh
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .local:
            guard !container.contains(.target), !container.contains(.persistenceOwner),
                !container.contains(.sessionName), !container.contains(.remoteExecutablePath)
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "A local pane execution plan cannot contain SSH fields."
                )
            }
            self = .local
        case .ssh:
            let execution = SSHExecution(
                target: try container.decode(RemoteTarget.self, forKey: .target),
                persistenceOwner: try container.decode(
                    PersistenceOwner.self,
                    forKey: .persistenceOwner
                ),
                sessionName: try container.decodeIfPresent(
                    RemoteSessionName.self,
                    forKey: .sessionName
                ),
                remoteExecutablePath: try container.decodeIfPresent(
                    String.self,
                    forKey: .remoteExecutablePath
                )
            )
            guard let execution else {
                throw DecodingError.dataCorruptedError(
                    forKey: .persistenceOwner,
                    in: container,
                    debugDescription:
                        "A remote pane execution plan's persistence owner and zmx fields disagree."
                )
            }
            self = .ssh(execution)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            try container.encode(Kind.local, forKey: .kind)
        case .ssh(let execution):
            try container.encode(Kind.ssh, forKey: .kind)
            try container.encode(execution.target, forKey: .target)
            try container.encode(execution.persistenceOwner, forKey: .persistenceOwner)
            try container.encodeIfPresent(execution.sessionName, forKey: .sessionName)
            try container.encodeIfPresent(
                execution.remoteExecutablePath,
                forKey: .remoteExecutablePath
            )
        }
    }
}
