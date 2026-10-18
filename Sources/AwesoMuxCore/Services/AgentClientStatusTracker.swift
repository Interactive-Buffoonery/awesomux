import Foundation

/// Ordered, fresh snapshots from one terminal client, independent of its shared server.
public struct AgentClientStatusTracker: Sendable {
    public private(set) var current: AgentClientStatusEvidence?
    public private(set) var inputReady = false
    public private(set) var observationStartedAt: TimeInterval

    public init(observationStartedAt: TimeInterval = Date().timeIntervalSince1970) {
        self.observationStartedAt = observationStartedAt
    }

    /// A new watcher cannot reuse readiness captured before it observed the client.
    public mutating func invalidateObservation(now: TimeInterval) {
        inputReady = false
        if now.isFinite, now >= 0 { observationStartedAt = max(observationStartedAt, now) }
    }

    public mutating func accept(
        _ evidence: AgentClientStatusEvidence,
        inputReady: Bool,
        observedPID: Int,
        observedStartedAt: Int,
        foregroundMatchesProvider: Bool,
        now: TimeInterval
    ) -> Bool {
        guard evidence.isValid,
            // Coarse producer/app clocks may tie across a watch restart.
            evidence.capturedAt > observationStartedAt,
            Self.isFresh(evidence, now: now),
            evidence.pid == observedPID, evidence.startedAt == observedStartedAt,
            foregroundMatchesProvider
        else { return false }
        if let current, current.pid == evidence.pid, current.startedAt == evidence.startedAt {
            guard current.clientID == evidence.clientID, evidence.sequence > current.sequence,
                evidence.completedTurns >= current.completedTurns,
                evidence.threadEpoch >= current.threadEpoch
            else { return false }
        }
        current = evidence
        self.inputReady = inputReady
        return true
    }

    public func isReady(observedPID: Int, observedStartedAt: Int, now: TimeInterval) -> Bool {
        guard inputReady, let current,
            current.pid == observedPID, current.startedAt == observedStartedAt
        else { return false }
        return Self.isFresh(current, now: now)
    }

    private static func isFresh(_ evidence: AgentClientStatusEvidence, now: TimeInterval) -> Bool {
        now.isFinite && evidence.capturedAt <= now + 1 && now - evidence.capturedAt <= 10
    }
}
