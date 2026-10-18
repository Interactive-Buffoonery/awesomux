import Foundation

public struct AgentClientStatusEvidence: Codable, Equatable, Sendable {
    public var clientID: String
    public var sequence: UInt64
    public var completedTurns: UInt64
    public var threadEpoch: UInt64
    public var pid: Int
    public var startedAt: Int
    public var capturedAt: TimeInterval

    public init(
        clientID: String, sequence: UInt64, completedTurns: UInt64, threadEpoch: UInt64, pid: Int, startedAt: Int, capturedAt: TimeInterval
    ) {
        self.clientID = clientID
        self.sequence = sequence
        self.completedTurns = completedTurns
        self.threadEpoch = threadEpoch
        self.pid = pid
        self.startedAt = startedAt
        self.capturedAt = capturedAt
    }

    public var isValid: Bool {
        UUID(uuidString: clientID) != nil && sequence > 0 && threadEpoch > 0 && pid > 0 && startedAt > 0
            && capturedAt.isFinite && capturedAt >= 0
    }
}
