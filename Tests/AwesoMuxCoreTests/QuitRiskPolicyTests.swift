import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("QuitRiskPolicy")
struct QuitRiskPolicyTests {
    enum Scope: Sendable { case quit, close }

    struct Scenario: Sendable {
        let scope: Scope
        var kind: AgentKind = .shell
        var exec: AgentExecutionState = .idle
        var fresh = true
        var away = false
        var promptObserved = true
        let liveness: ForegroundProcessLiveness
        let isRisk: Bool
        let reason: QuitRiskReason
    }

    static let scenarios: [Scenario] =
        [
            Scenario(scope: .quit, away: true, liveness: .bridged, isRisk: false, reason: .daemonBacked),
            Scenario(scope: .quit, liveness: .bridgedBusy, isRisk: false, reason: .daemonBacked),
            Scenario(scope: .quit, away: true, liveness: .bridgedIndeterminate, isRisk: false, reason: .daemonBacked),
            Scenario(scope: .quit, kind: .codex, exec: .thinking, liveness: .unsampled, isRisk: true, reason: .activeAgentExecution),
            Scenario(
                scope: .quit, kind: .codex, exec: .thinking, fresh: false, liveness: .unsampled, isRisk: false, reason: .noLiveProcess),
            Scenario(scope: .quit, kind: .codex, exec: .running, liveness: .idleShell, isRisk: true, reason: .activeAgentExecution),
            Scenario(scope: .quit, kind: .claudeCode, liveness: .unsampled, isRisk: false, reason: .noLiveProcess),
            Scenario(scope: .quit, exec: .running, liveness: .unsampled, isRisk: false, reason: .noLiveProcess),
            Scenario(scope: .quit, exec: .running, liveness: .idleShell, isRisk: false, reason: .shellAtPrompt),
            Scenario(scope: .close, away: true, liveness: .bridged, isRisk: true, reason: .terminalAwayFromPrompt),
            Scenario(scope: .close, liveness: .bridged, isRisk: false, reason: .shellAtPrompt),
            Scenario(scope: .close, liveness: .bridgedBusy, isRisk: true, reason: .liveForegroundProcess),
            Scenario(
                scope: .close, away: true, promptObserved: false, liveness: .bridgedIndeterminate, isRisk: true, reason: .indeterminate),
            Scenario(
                scope: .close, kind: .codex, exec: .running, away: true, promptObserved: false, liveness: .bridgedIndeterminate,
                isRisk: true, reason: .activeAgentExecution),
            // #190: verified idle tree evidence is sufficient before the first prompt marker.
            Scenario(scope: .close, away: true, promptObserved: false, liveness: .bridged, isRisk: false, reason: .shellAtPrompt),
            Scenario(scope: .close, liveness: .bridgedIndeterminate, isRisk: false, reason: .shellAtPrompt),
            Scenario(scope: .close, away: true, liveness: .bridgedIndeterminate, isRisk: true, reason: .terminalAwayFromPrompt),
            Scenario(scope: .close, kind: .claudeCode, exec: .running, liveness: .bridged, isRisk: true, reason: .activeAgentExecution),
            Scenario(
                scope: .close, kind: .claudeCode, exec: .running, fresh: false, liveness: .bridged, isRisk: false, reason: .shellAtPrompt),
        ]
        + [AgentKind.pi, .openCode, .claudeCode, .codex, .generic].flatMap { kind in
            [
                Scenario(scope: .quit, kind: kind, liveness: .liveCommand, isRisk: true, reason: .liveAgentProcess),
                Scenario(scope: .quit, kind: kind, exec: .running, liveness: .unsampled, isRisk: true, reason: .activeAgentExecution),
            ]
        }
        + [false, true].flatMap { away in
            [
                Scenario(scope: .quit, away: away, liveness: .exited, isRisk: false, reason: .processExited),
                Scenario(
                    scope: .quit, away: away, liveness: .liveCommand, isRisk: true,
                    reason: away ? .terminalAwayFromPrompt : .liveForegroundProcess),
                Scenario(
                    scope: .quit, away: away, liveness: .busyShell, isRisk: true,
                    reason: away ? .terminalAwayFromPrompt : .backgroundJob),
                Scenario(
                    scope: .quit, away: away, liveness: .idleShell, isRisk: away,
                    reason: away ? .terminalAwayFromPrompt : .shellAtPrompt),
                Scenario(
                    scope: .quit, away: away, liveness: .unsampled, isRisk: away,
                    reason: away ? .terminalAwayFromPrompt : .noLiveProcess),
                Scenario(
                    scope: .quit, away: away, liveness: .indeterminate, isRisk: true,
                    reason: away ? .terminalAwayFromPrompt : .indeterminate),
            ]
        }

    @Test("quit and destructive close preserve their safety boundaries", arguments: scenarios)
    func riskDecision(scenario: Scenario) {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let age = scenario.fresh ? 1 : TerminalPane.staleAgentActivityThreshold + 1
        let inputs = QuitRiskInputs(
            agentKind: scenario.kind,
            agentExecutionState: scenario.exec,
            lastAgentStateChangeAt: now.addingTimeInterval(-age),
            awayFromPrompt: scenario.away,
            promptObserved: scenario.promptObserved,
            liveness: scenario.liveness
        )
        let quit = QuitRiskPolicy.decision(inputs, at: now)
        let close = QuitRiskPolicy.closeDecision(inputs, at: now)
        let decision = scenario.scope == .quit ? quit : close
        #expect(decision.isRisk == scenario.isRisk)
        #expect(decision.reason == scenario.reason)
        if [.exited, .liveCommand, .busyShell, .idleShell, .unsampled, .indeterminate].contains(scenario.liveness) {
            #expect(close == quit)
        }
    }
}
