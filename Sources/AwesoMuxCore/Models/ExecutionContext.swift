import Foundation

public enum ExecutionOperation: Hashable, Sendable {
  case inspectLocalFilesystem
  case revealInFinder
  case inspectLocalProcess
  case launchLocalShellFallback
  case closeLocalPresentation
  case terminatePersistentSession
  case readRemoteResource
  case reconnect
}

public enum CapabilityDenialReason: Hashable, Sendable {
  case requiresLocalExecution
  case requiresRemoteExecution
  case unavailable
}

public enum CapabilityDecision: Hashable, Sendable {
  case allowed
  case denied(CapabilityDenialReason)

  public var isAllowed: Bool {
    self == .allowed
  }
}

public struct ExecutionContext: Hashable, Sendable {
  public let plan: PaneExecutionPlan
  public let connectionHealth: RemoteConnectionHealth
  public let reconnectState: RemoteReconnectState?

  public init(
    plan: PaneExecutionPlan,
    connectionHealth: RemoteConnectionHealth = .active,
    reconnectState: RemoteReconnectState? = nil
  ) {
    self.plan = plan
    self.connectionHealth = connectionHealth
    self.reconnectState = reconnectState
  }

  public func capability(_ operation: ExecutionOperation) -> CapabilityDecision {
    switch (plan, operation) {
    case (.local, .inspectLocalFilesystem),
      (.local, .revealInFinder),
      (.local, .inspectLocalProcess),
      (.local, .launchLocalShellFallback),
      (.local, .closeLocalPresentation),
      (.local, .terminatePersistentSession):
      .allowed
    case (.local, .readRemoteResource), (.local, .reconnect):
      .denied(.requiresRemoteExecution)
    case (.ssh, .inspectLocalFilesystem),
      (.ssh, .revealInFinder),
      (.ssh, .inspectLocalProcess),
      (.ssh, .launchLocalShellFallback):
      .denied(.requiresLocalExecution)
    case (.ssh, .closeLocalPresentation),
      (.ssh, .terminatePersistentSession):
      .allowed
    case (.ssh, .readRemoteResource):
      connectionHealth == .active ? .allowed : .denied(.unavailable)
    case (.ssh, .reconnect):
      reconnectState == nil ? .denied(.unavailable) : .allowed
    }
  }

  public func resourceIdentity(for path: ResourcePath) -> ResourceIdentity {
    ResourceIdentity(location: plan.location, path: path)
  }
}
