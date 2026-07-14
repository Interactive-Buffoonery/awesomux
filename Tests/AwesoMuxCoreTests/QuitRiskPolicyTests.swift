// Tests/AwesoMuxCoreTests/QuitRiskPolicyTests.swift
import Testing
import Foundation
@testable import AwesoMuxCore

@Suite("QuitRiskPolicy")
struct QuitRiskPolicyTests {
    private let now = Date()
    private func fresh() -> Date { now.addingTimeInterval(-1) }
    private func stale() -> Date { now.addingTimeInterval(-(TerminalPane.staleAgentActivityThreshold + 1)) }

    private func decide(
        _ kind: AgentKind = .shell,
        exec: AgentExecutionState = .idle,
        changed: Date? = nil,
        away: Bool = false,
        liveness: ForegroundProcessLiveness
    ) -> QuitRiskDecision {
        QuitRiskPolicy.decision(
            QuitRiskInputs(
                agentKind: kind,
                agentExecutionState: exec,
                lastAgentStateChangeAt: changed ?? now,
                awayFromPrompt: away,
                liveness: liveness
            ),
            at: now
        )
    }

    @Test("bridged and exited are authoritatively safe, even when away from prompt")
    func authoritativeSafe() {
        #expect(!decide(away: true, liveness: .bridged).isRisk)
        #expect(decide(liveness: .bridged).reason == .daemonBacked)
        #expect(!decide(away: true, liveness: .exited).isRisk)
        #expect(decide(liveness: .exited).reason == .processExited)
    }

    @Test("background job on an otherwise-idle shell is a risk")
    func backgroundJob() {
        let d = decide(liveness: .busyShell)
        #expect(d.isRisk)
        #expect(d.reason == .backgroundJob)
    }

    @Test("live foreground command is a risk (shell vs agent reason)")
    func liveCommand() {
        #expect(decide(.shell, liveness: .liveCommand).reason == .liveForegroundProcess)
        #expect(decide(.claudeCode, liveness: .liveCommand).reason == .liveAgentProcess)
    }

    @Test("idle shell at prompt is safe; away-from-prompt overrides to risk")
    func idleShell() {
        #expect(!decide(liveness: .idleShell).isRisk)
        #expect(decide(liveness: .idleShell).reason == .shellAtPrompt)
        #expect(decide(away: true, liveness: .idleShell).reason == .terminalAwayFromPrompt)
    }

    @Test("indeterminate warns")
    func indeterminate() {
        #expect(decide(liveness: .indeterminate).isRisk)
        #expect(decide(liveness: .indeterminate).reason == .indeterminate)
    }

    @Test("agent freshness is the fallback when no live foreground is sampled")
    func agentFreshnessFallback() {
        // unsampled (no surface) + fresh agent run = risk; stale = safe.
        #expect(decide(.codex, exec: .thinking, changed: fresh(), liveness: .unsampled).reason == .activeAgentExecution)
        #expect(!decide(.codex, exec: .thinking, changed: stale(), liveness: .unsampled).isRisk)
        // idleShell foreground (agent exited to its shell) + fresh exec still warns.
        #expect(decide(.codex, exec: .running, changed: fresh(), liveness: .idleShell).reason == .activeAgentExecution)
    }

    @Test("liveness/display divergence: attention without a live process is safe; a live process with idle exec is a risk")
    func divergence() {
        // Agent flagged needsAttention but no live process sampled, idle exec → safe.
        #expect(!decide(.claudeCode, exec: .idle, liveness: .unsampled).isRisk)
        // Live agent process but execution state reads idle → still a risk.
        #expect(decide(.claudeCode, exec: .idle, liveness: .liveCommand).isRisk)
    }

    @Test("shells never take the agent-execution path")
    func shellsIgnoreExecution() {
        #expect(!decide(.shell, exec: .running, changed: fresh(), liveness: .unsampled).isRisk)
        #expect(!decide(.shell, exec: .running, changed: fresh(), liveness: .idleShell).isRisk)
    }

    @Test("all non-shell agent kinds follow the agent liveness/freshness paths")
    func nonShellAgentKindsCoverage() {
        // Every non-shell kind (incl. pi/openCode) gets .liveAgentProcess for a
        // live foreground and the agent-execution fallback when unsampled.
        for kind in [AgentKind.pi, .openCode, .claudeCode, .codex] {
            #expect(decide(kind, liveness: .liveCommand).reason == .liveAgentProcess)
            #expect(decide(kind, exec: .running, changed: fresh(), liveness: .unsampled).reason == .activeAgentExecution)
        }
    }

    // MARK: - closeDecision (destroy semantics)

    private func decideClose(
        _ kind: AgentKind = .shell,
        exec: AgentExecutionState = .idle,
        changed: Date? = nil,
        away: Bool = false,
        promptObserved: Bool = true,
        liveness: ForegroundProcessLiveness
    ) -> QuitRiskDecision {
        QuitRiskPolicy.closeDecision(
            QuitRiskInputs(
                agentKind: kind,
                agentExecutionState: exec,
                lastAgentStateChangeAt: changed ?? now,
                awayFromPrompt: away,
                promptObserved: promptObserved,
                liveness: liveness
            ),
            at: now
        )
    }

    @Test("close: a bridged pane away from its prompt is a risk — the close kills the daemon")
    func closeBridgedAwayFromPrompt() {
        let d = decideClose(away: true, liveness: .bridged)
        #expect(d.isRisk)
        #expect(d.reason == .terminalAwayFromPrompt)
    }

    @Test("close: a bridged pane at its prompt is safe")
    func closeBridgedAtPrompt() {
        let d = decideClose(liveness: .bridged)
        #expect(!d.isRisk)
        #expect(d.reason == .shellAtPrompt)
    }

    @Test("close: an unobserved prompt marker does not make an idle bridge risky")
    func closeBridgedWithoutObservedPrompt() {
        let d = decideClose(away: true, promptObserved: false, liveness: .bridged)
        #expect(!d.isRisk)
        #expect(d.reason == .shellAtPrompt)
        #expect(
            decideClose(
                .codex,
                exec: .running,
                changed: fresh(),
                away: true,
                promptObserved: false,
                liveness: .bridged
            ).reason == .activeAgentExecution
        )
    }

    @Test("close: a bridged agent with fresh execution is a risk even at the prompt")
    func closeBridgedFreshAgent() {
        #expect(decideClose(.claudeCode, exec: .running, changed: fresh(), liveness: .bridged).reason == .activeAgentExecution)
        #expect(!decideClose(.claudeCode, exec: .running, changed: stale(), liveness: .bridged).isRisk)
    }

    @Test("close: non-bridged panes match the quit decision exactly")
    func closeNonBridgedPassthrough() {
        for liveness in [ForegroundProcessLiveness.exited, .liveCommand, .busyShell, .idleShell, .unsampled, .indeterminate] {
            for away in [false, true] {
                #expect(decideClose(away: away, liveness: liveness) == decide(away: away, liveness: liveness))
            }
        }
    }

    @Test("a bridged pane away from prompt is quit-safe but close-risky")
    func bridgedAwayFromPromptDivergesByScope() {
        let now = Date()
        let inputs = QuitRiskInputs(
            agentKind: .shell,
            agentExecutionState: .idle,
            lastAgentStateChangeAt: now,
            awayFromPrompt: true,
            liveness: .bridged
        )
        #expect(QuitRiskPolicy.decision(inputs, at: now).isRisk == false)
        #expect(QuitRiskPolicy.closeDecision(inputs, at: now).isRisk == true)
    }
}
