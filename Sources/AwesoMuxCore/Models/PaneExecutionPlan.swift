import Foundation

public enum PersistenceOwner: String, Codable, Hashable, Sendable {
  case localAmx
}

public struct SSHExecution: Codable, Hashable, Sendable {
  public let target: RemoteTarget
  public let persistenceOwner: PersistenceOwner

  public init(target: RemoteTarget, persistenceOwner: PersistenceOwner = .localAmx) {
    self.target = target
    self.persistenceOwner = persistenceOwner
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
}

extension PaneExecutionPlan: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind
    case target
    case persistenceOwner
  }

  private enum Kind: String, Codable {
    case local
    case ssh
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .local:
      guard !container.contains(.target), !container.contains(.persistenceOwner) else {
        throw DecodingError.dataCorruptedError(
          forKey: .kind,
          in: container,
          debugDescription: "A local pane execution plan cannot contain SSH fields."
        )
      }
      self = .local
    case .ssh:
      self = .ssh(
        SSHExecution(
          target: try container.decode(RemoteTarget.self, forKey: .target),
          persistenceOwner: try container.decode(
            PersistenceOwner.self,
            forKey: .persistenceOwner
          )
        ))
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
    }
  }
}
