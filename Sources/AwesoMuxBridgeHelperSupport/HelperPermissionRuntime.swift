import AwesoMuxBridgeProtocol
import Foundation

public struct HelperPermissionRuntime {
    public enum DecisionOutcome: Sendable, Equatable {
        case applied(PermissionDecision.Decision, PermissionDecision.Scope)
        case expired
        case connectionLost
    }

    public enum AdmissionOutcome: Sendable, Equatable {
        case admitted
        case rejected
        case overflow(decision: PermissionDecision.Decision, resolved: BridgeEnvelope)
    }

    private var pending = BridgePendingRequestMap()
    private let token: String
    private let session: String
    private let makeID: () -> String

    public init(token: String, session: String, makeID: @escaping () -> String = { UUID().uuidString }) {
        self.token = token
        self.session = session
        self.makeID = makeID
    }

    public var pendingCount: Int { pending.count }

    public func peek(id: String) -> BridgePendingRequestMap.Entry? {
        pending.peek(id: id)
    }

    public mutating func admit(envelope: BridgeEnvelope, now: Date) -> AdmissionOutcome {
        guard case .permissionRequest(let request) = envelope.message else {
            return .rejected
        }

        switch pending.admit(
            id: envelope.id,
            target: request.target,
            tool: request.tool,
            expiresAt: Date(timeIntervalSince1970: request.expiresAt)
        ) {
        case .admitted:
            return .admitted
        case .overflow:
            return .overflow(
                decision: .deny,
                resolved: resolvedEnvelope(for: envelope.id, reason: .overflow, now: now)
            )
        case .duplicate, .invalidDeadline:
            return .rejected
        }
    }

    public mutating func acceptDecision(_ envelope: BridgeEnvelope, now: Date) -> DecisionOutcome? {
        guard case .permissionDecision(let decision) = envelope.message,
              let entry = pending.peek(id: decision.inReplyTo),
              entry.target == decision.target
        else {
            return nil
        }

        switch pending.resolve(id: decision.inReplyTo, event: .decisionApplied, now: now) {
        case .resolved(_, .decisionApplied):
            return .applied(decision.decision, decision.scope)
        case .resolved(_, .expired):
            return .expired
        case .resolved(_, _), .unknown:
            return nil
        }
    }

    public mutating func sweepExpired(now: Date) -> [BridgeEnvelope] {
        pending.sweepExpired(now: now).map {
            resolvedEnvelope(for: $0.id, reason: .expired, now: now)
        }
    }

    public mutating func connectionLost() -> [BridgePendingRequestMap.Entry] {
        pending.drainAll()
    }

    private func resolvedEnvelope(for requestID: String, reason: PermissionResolved.Reason, now: Date) -> BridgeEnvelope {
        BridgeEnvelope(
            token: token,
            session: session,
            id: makeID(),
            ts: now.timeIntervalSince1970,
            message: .permissionResolved(PermissionResolved(inReplyTo: requestID, reason: reason))
        )
    }
}
