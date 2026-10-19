import AwesoMuxBridgeProtocol
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
    func mismatchedTargetLeavesPendingRequestUntouched() {
        var runtime = HelperPermissionRuntime(token: "token", session: "session")
        _ = runtime.admit(envelope: request(id: "req", target: "submitted"), now: now)

        #expect(runtime.acceptDecision(decision(replyTo: "req", target: "ambient"), now: now) == nil)
        #expect(runtime.peek(id: "req")?.target == "submitted")
    }

    @Test
    func connectionLossFailClosedDrainsPending() {
        var runtime = HelperPermissionRuntime(token: "token", session: "session")
        _ = runtime.admit(envelope: request(id: "one", target: "1"), now: now)
        _ = runtime.admit(envelope: request(id: "two", target: "2"), now: now)

        #expect(Set(runtime.connectionLost().map(\.id)) == ["one", "two"])
        #expect(runtime.pendingCount == 0)
    }

}
