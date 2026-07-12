import AwesoMuxCore
import Foundation
import Testing
@testable import AwesoMuxBridgeHelperSupport

@Suite
struct HelperPermissionRuntimeTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func request(id: String, target: String, expiresAt: Double = 1_700_000_100) -> BridgeEnvelope {
        BridgeEnvelope(
            token: "token", session: "session", id: id, ts: now.timeIntervalSince1970,
            message: .permissionRequest(PermissionRequest(tool: "Bash", target: target, expiresAt: expiresAt))
        )
    }

    private func decision(replyTo: String, target: String) -> BridgeEnvelope {
        BridgeEnvelope(
            token: "token", session: "session", id: "decision", ts: now.timeIntervalSince1970,
            message: .permissionDecision(
                PermissionDecision(inReplyTo: replyTo, decision: .allow, scope: .once, target: target)
            )
        )
    }

    @Test
    func matchingDecisionResolvesPendingRequest() {
        var runtime = HelperPermissionRuntime(token: "token", session: "session")
        #expect(runtime.admit(envelope: request(id: "req", target: "safe"), now: now) == .admitted)

        let outcome = runtime.acceptDecision(decision(replyTo: "req", target: "safe"), now: now)

        #expect(outcome == .applied(.allow, .once))
        #expect(runtime.pendingCount == 0)
    }

    @Test
    func mismatchedTargetLeavesPendingRequestUntouched() {
        var runtime = HelperPermissionRuntime(token: "token", session: "session")
        _ = runtime.admit(envelope: request(id: "req", target: "submitted"), now: now)

        #expect(runtime.acceptDecision(decision(replyTo: "req", target: "ambient"), now: now) == nil)
        #expect(runtime.peek(id: "req")?.target == "submitted")
    }

    @Test
    func wrongDirectionEnvelopeIsRejected() {
        var runtime = HelperPermissionRuntime(token: "token", session: "session")
        #expect(runtime.acceptDecision(request(id: "req", target: "target"), now: now) == nil)
    }

    @Test
    func connectionLossFailClosedDrainsPending() {
        var runtime = HelperPermissionRuntime(token: "token", session: "session")
        _ = runtime.admit(envelope: request(id: "one", target: "1"), now: now)
        _ = runtime.admit(envelope: request(id: "two", target: "2"), now: now)

        #expect(Set(runtime.connectionLost().map(\.id)) == ["one", "two"])
        #expect(runtime.pendingCount == 0)
    }

    @Test
    func expiryEmitsPermissionResolved() {
        var runtime = HelperPermissionRuntime(token: "token", session: "session", makeID: { "resolved" })
        _ = runtime.admit(envelope: request(id: "req", target: "target", expiresAt: now.timeIntervalSince1970), now: now)

        let expired = runtime.sweepExpired(now: now)

        #expect(expired.count == 1)
        #expect(expired.first?.message == .permissionResolved(PermissionResolved(inReplyTo: "req", reason: .expired)))
    }

    @Test
    func overflowDeniesFifthWhileFourPendingStayUntouched() {
        var runtime = HelperPermissionRuntime(token: "token", session: "session", makeID: { "overflow" })
        for index in 0..<BridgeTunables.pendingRequestCap {
            #expect(runtime.admit(envelope: request(id: "req-\(index)", target: "\(index)"), now: now) == .admitted)
        }

        let outcome = runtime.admit(envelope: request(id: "fifth", target: "5"), now: now)

        guard case .overflow(let decision, let envelope) = outcome else {
            Issue.record("expected overflow")
            return
        }
        #expect(decision == .deny)
        #expect(envelope.message == .permissionResolved(PermissionResolved(inReplyTo: "fifth", reason: .overflow)))
        #expect(runtime.pendingCount == BridgeTunables.pendingRequestCap)
        for index in 0..<BridgeTunables.pendingRequestCap {
            #expect(runtime.peek(id: "req-\(index)")?.target == "\(index)")
        }
    }
}
