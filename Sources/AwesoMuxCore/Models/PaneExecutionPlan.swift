import Foundation

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
    /// Nil for `.localAmx`. Names the session the remote host keeps running.
    public let sessionName: RemoteSessionName?

    public init(target: RemoteTarget) {
        self.target = target
        self.persistenceOwner = .localAmx
        self.sessionName = nil
    }

    /// The remote-owned counterpart, non-failable because naming the session IS
    /// the `.remoteZmx` invariant. Callers that know which owner they want reach
    /// for one of these two; the failable init below exists for the decode seam,
    /// where owner and name arrive separately and can contradict each other.
    public init(target: RemoteTarget, remoteSessionName: RemoteSessionName) {
        self.target = target
        self.persistenceOwner = .remoteZmx
        self.sessionName = remoteSessionName
    }

    /// Returns nil when the persistence owner and its remote fields disagree:
    /// local-amx panes carry no remote session identity, and remote-owned panes
    /// must name their session. Where the remote backend LIVES is not part of
    /// the plan — the attach command resolves it on the far host.
    public init?(
        target: RemoteTarget,
        persistenceOwner: PersistenceOwner,
        sessionName: RemoteSessionName?
    ) {
        switch persistenceOwner {
        case .localAmx:
            guard sessionName == nil else { return nil }
        case .remoteZmx:
            guard sessionName != nil else { return nil }
        }
        self.target = target
        self.persistenceOwner = persistenceOwner
        self.sessionName = sessionName
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
                !container.contains(.sessionName)
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
                )
            )
            guard let execution else {
                throw DecodingError.dataCorruptedError(
                    forKey: .persistenceOwner,
                    in: container,
                    debugDescription:
                        "A remote pane execution plan's persistence owner and session name disagree."
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
        }
    }
}
