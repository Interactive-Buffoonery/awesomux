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
    enum Observation {
        case local(ForegroundProcessLiveness)
        case remote(RemoteForegroundLiveness)
        case sshEntry(Bool)
    }

    @Test(
        arguments: [AgentKind.claudeCode, .codex, .openCode, .pi, .grok, .hermes, .generic].map {
            ($0, Observation.local(.idleShell), true)
        }
            + [
                ForegroundProcessLiveness.unsampled, .bridgedBusy, .bridgedIndeterminate,
                .exited, .busyShell, .liveCommand, .indeterminate,
            ].map {
                (AgentKind.openCode, Observation.local($0), false)
            }
            + [
                (.codex, .local(.bridged), true),
                (.shell, .local(.idleShell), false),
                (.claudeCode, .remote(.idleShell), true),
                (.claudeCode, .remote(.liveCommand), false),
                (.shell, .remote(.idleShell), false),
                (.claudeCode, .sshEntry(true), true),
                (.claudeCode, .sshEntry(false), false),
                (.shell, .sshEntry(true), false),
            ]
    )
    func resetsOnlyIdleAgent(kind: AgentKind, observation: Observation, expected: Bool) {
        let actual: Bool
        switch observation {
        case .local(let liveness):
            actual = AgentLivenessPolicy.shouldResetAgentChrome(agentKind: kind, liveness: liveness)
        case .remote(let liveness):
            actual = AgentLivenessPolicy.shouldResetAgentChrome(agentKind: kind, remoteLiveness: liveness)
        case .sshEntry(let justObserved):
            actual = AgentLivenessPolicy.shouldResetAgentChromeOnSSHForegroundObservation(
                agentKind: kind, justObservedSSHClient: justObserved)
        }
        #expect(actual == expected)
    }
}
