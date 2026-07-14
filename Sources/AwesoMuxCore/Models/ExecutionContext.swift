import Foundation

public enum ExecutionOperation: Hashable, Sendable {
    case inspectLocalFilesystem
    case revealInFinder
    case copyLocalPath
    case launchLocalShellFallback
    case stageLocalDocumentPath
}

public enum CapabilityDenialReason: Hashable, Sendable {
    case requiresLocalExecution
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

    public init(plan: PaneExecutionPlan) {
        self.plan = plan
    }

    public func capability(_ operation: ExecutionOperation) -> CapabilityDecision {
        switch (plan, operation) {
        case (.local, .inspectLocalFilesystem),
            (.local, .revealInFinder),
            (.local, .copyLocalPath),
            (.local, .launchLocalShellFallback),
            (.local, .stageLocalDocumentPath):
            .allowed
        case (.ssh, .inspectLocalFilesystem),
            (.ssh, .revealInFinder),
            (.ssh, .copyLocalPath),
            (.ssh, .launchLocalShellFallback),
            (.ssh, .stageLocalDocumentPath):
            .denied(.requiresLocalExecution)
        }
    }

    public func resourceIdentity(for path: ResourcePath) -> ResourceIdentity {
        ResourceIdentity(location: plan.location, path: path)
    }
}
