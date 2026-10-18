import AwesoMuxBridgeProtocol
import Testing
@testable import AwesoMuxCore

@Suite("ForegroundProcessLiveness.classify")
struct ForegroundProcessLivenessTests {
    @Test(arguments: [
        (false, true, "zsh" as String?, false as Bool?, ForegroundProcessLiveness.exited),
        (false, true, nil, nil, .exited),
        (false, false, nil, nil, .indeterminate),
        (false, false, "vim", false, .liveCommand),
        (false, false, "node", nil, .liveCommand),
        (false, false, "-zsh", false, .idleShell),
        (false, false, "zsh", true, .busyShell),
        (false, false, "bash", nil, .indeterminate),
        (true, false, "-zsh", false, .bridged),
        (true, false, "-zsh", true, .bridgedBusy),
        (true, false, "sleep", false, .bridgedBusy),
        (true, false, nil, nil, .bridgedIndeterminate),
        (true, false, "-zsh", nil, .bridgedIndeterminate),
    ])
    func classifiesForeground(bridged: Bool, exited: Bool, command: String?, children: Bool?, expected: ForegroundProcessLiveness) {
        let actual =
            bridged
            ? ForegroundProcessLiveness.classifyBridged(rootComm: command, rootHasChildren: children)
            : ForegroundProcessLiveness.classify(processExited: exited, foregroundComm: command, foregroundHasChildren: children)
        #expect(actual == expected)
    }
}

@Suite("AgentLivenessPolicy.shouldResetAgentChrome (INT-552)")
struct AgentLivenessPolicyTests {
    @Test(
        arguments: [AgentKind.claudeCode, .codex, .openCode, .pi, .grok, .hermes, .generic].map {
            ($0, ForegroundProcessLiveness.idleShell, true)
        }
            + [
                ForegroundProcessLiveness.unsampled, .bridgedBusy, .bridgedIndeterminate,
                .exited, .busyShell, .liveCommand, .indeterminate,
            ].map {
                (AgentKind.openCode, $0, false)
        }
    )
    func resetsOnlyIdleAgent(kind: AgentKind, liveness: ForegroundProcessLiveness, expected: Bool) {
        #expect(AgentLivenessPolicy.shouldResetAgentChrome(agentKind: kind, liveness: liveness) == expected)
    }
}
