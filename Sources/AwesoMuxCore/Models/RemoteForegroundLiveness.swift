import AwesoMuxBridgeProtocol
import Foundation

public enum RemoteForegroundLiveness: Sendable, Hashable {
    case idleShell
    case busyShell
    case liveCommand
    case indeterminate
    case sessionNotFound

    public init(_ report: RemoteForegroundLivenessReport.State) {
        switch report {
        case .idleShell: self = .idleShell
        case .busyShell: self = .busyShell
        case .liveCommand: self = .liveCommand
        case .indeterminate: self = .indeterminate
        case .gone: self = .sessionNotFound
        }
    }
}

/// Runtime-only evidence from the remote helper. Every identity field belongs
/// to the attach that produced the sample, so callers can reject a late result
/// instead of applying it to a replacement pane or SSH generation.
public struct RemoteForegroundLivenessSnapshot: Sendable, Hashable {
    public let workspaceID: UUID
    public let paneID: UUID
    public let terminalSessionID: TerminalSessionID
    public let connectionGeneration: String
    public let liveness: RemoteForegroundLiveness
    public let sampledAt: Date

    public init(
        workspaceID: UUID,
        paneID: UUID,
        terminalSessionID: TerminalSessionID,
        connectionGeneration: String,
        liveness: RemoteForegroundLiveness,
        sampledAt: Date
    ) {
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.terminalSessionID = terminalSessionID
        self.connectionGeneration = connectionGeneration
        self.liveness = liveness
        self.sampledAt = sampledAt
    }
}
