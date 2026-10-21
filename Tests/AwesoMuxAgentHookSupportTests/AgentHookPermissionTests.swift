import Foundation
import Testing
@testable import AwesoMuxAgentHookSupport
@testable import AwesoMuxCore

@Suite
struct AgentHookPermissionTests {
    enum ReceptionBoundary: CaseIterable {
        case wallAtExpiry, wallAfterExpiry, monotonicAtExpiry, monotonicAfterExpiry, valid
    }

    // A read starts while both clocks are valid, but its decoded response can
    // reach stdout at/after either original deadline. Consuming it must end the
    // invocation even when no output (and therefore no ACK) is permitted.
    @Test(arguments: ReceptionBoundary.allCases, LocalPermissionChoice.allCases)
    func decodedResponseConsumesInvocationAtOutputBoundary(boundary: ReceptionBoundary, choice: LocalPermissionChoice) throws {
        let startedAt = Date(timeIntervalSince1970: 1000)
        let startedInstant = ContinuousClock.now
        let deadline = startedInstant.advanced(by: .seconds(120))
        let request = LocalPermissionRequest(
            target: .init(runtimeID: UUID(), workspaceID: UUID(), paneID: UUID(), version: UUID()),
            providerSessionID: "claude-session", invocationID: UUID(), toolUseID: "tool-1", helperPID: 123,
            helperStartMicroseconds: 1, expiresAt: startedAt.addingTimeInterval(120), tool: "Bash", summary: "echo hello"
        )
        var wallNow = request.expiresAt.addingTimeInterval(-1)
        var monotonicNow = deadline.advanced(by: .seconds(-1))
        #expect(wallNow < request.expiresAt)
        #expect(monotonicNow < deadline)
        let buffered = try JSONEncoder().encode(LocalPermissionOutcome(identity: request.identity, state: .delivering, choice: choice))
        let outcome = try JSONDecoder().decode(LocalPermissionOutcome.self, from: buffered)
        switch boundary {
        case .wallAtExpiry: wallNow = request.expiresAt
        case .wallAfterExpiry: wallNow = request.expiresAt.addingTimeInterval(1)
        case .monotonicAtExpiry: monotonicNow = deadline
        case .monotonicAfterExpiry: monotonicNow = deadline.advanced(by: .seconds(1))
        case .valid:
            wallNow = request.expiresAt.addingTimeInterval(-0.001)
            monotonicNow = deadline.advanced(by: .milliseconds(-1))
        }
        var effects: [String] = []
        let consumed = AgentHookPermission.consumeResponse(
            outcome, request: request, deadline: deadline,
            wallNow: { wallNow }, monotonicNow: { monotonicNow },
            output: {
                effects.append($0); return true
            },
            acknowledge: { effects.append("ack") }
        )
        #expect(consumed, "A decoded matching response must not authorize fallback, including after expiry")
        if boundary == .valid {
            #expect(
                effects == [
                    "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"\(choice.rawValue)\"}}}",
                    "ack",
                ])
        } else {
            #expect(effects.isEmpty, "Expired responses must invoke neither stdout nor ACK")
        }
    }
}
