import AwesoMuxBridgeProtocol
import Testing

@testable import AwesoMuxCore

@Suite("Agent prompt gate")
struct AgentPromptGateTests {
    private static let defaultGeneration = AgentForegroundIncarnation(pid: 4242, startedAt: 1_000)

    private func verdict(
        kind: AgentKind,
        state: AgentState = .waiting,
        enabled: Bool = true,
        comm: String? = nil,
        verifiedGeneration: AgentForegroundIncarnation? = defaultGeneration,
        observedGeneration: AgentForegroundIncarnation? = defaultGeneration
    ) -> AgentPromptGate.Verdict {
        AgentPromptGate.verdict(
            agentKind: kind,
            agentState: state,
            isIntegrationEnabled: { _ in enabled },
            observedForegroundCommand: comm,
            verifiedWaitingForegroundGeneration: verifiedGeneration,
            observedForegroundGeneration: observedGeneration
        )
    }

    @Test(
        "consent-gated providers decline when their integration is disabled",
        arguments: [AgentKind.pi, .openCode]
    )
    func disabledConsentProvidersDecline(kind: AgentKind) {
        #expect(
            verdict(kind: kind, enabled: false, comm: "pi")
                == .unavailable(.agentIntegrationDisabled(kind))
        )
    }

    @Test(
        "every non-waiting state declines",
        arguments: AgentState.allCases.filter { $0 != .waiting }
    )
    func nonWaitingStatesDecline(state: AgentState) {
        #expect(
            verdict(kind: .claudeCode, state: state, comm: "claude")
                == .unavailable(.agentNotReceptive(.claudeCode))
        )
    }

    @Test(arguments: [
        (AgentKind.claudeCode, "claude"),
        (AgentKind.codex, "codex"),
        (AgentKind.pi, "pi"),
        (AgentKind.openCode, "opencode"),
        (AgentKind.claudeCode, "2.1.214"),
        (AgentKind.claudeCode, "claude.exe"),
        (AgentKind.codex, "codex.exe"),
        (AgentKind.pi, "pi.exe"),
        (AgentKind.openCode, "opencode.exe"),
    ])
    func verifiedProviders(kind: AgentKind, comm: String) {
        #expect(verdict(kind: kind, comm: comm) == .verified(kind))
    }

    @Test(arguments: [
        (AgentKind.shell, "claude"), (.grok, "claude"), (.hermes, "claude"), (.generic, "muse"),
    ])
    func unsupportedKindsDecline(kind: AgentKind, comm: String) {
        #expect(verdict(kind: kind, comm: comm) == .unavailable(.noVerifiedAgent))
    }

    @Test(
        arguments: [
            (AgentKind.claudeCode, "zsh"),
            (AgentKind.claudeCode, "vim"),
            (AgentKind.claudeCode, "less"),
            (AgentKind.claudeCode, "htop"),
            (AgentKind.claudeCode, "node"),
            (AgentKind.claudeCode, "python3"),
            (.codex, nil),
        ] as [(AgentKind, String?)])
    func foregroundMismatchDeclines(kind: AgentKind, comm: String?) {
        #expect(verdict(kind: kind, comm: comm) == .unavailable(.noVerifiedAgent))
    }

    @Test(arguments: [
        (AgentKind.pi, "node", "node"),
        (AgentKind.pi, "zsh", "zsh"),
        (AgentKind.pi, "vim", "vim"),
        (AgentKind.pi, "less", "less"),
        (AgentKind.pi, "htop", "htop"),
        (AgentKind.pi, "python3", "python3"),
        (AgentKind.pi, "tmux", "tmux"),
        (AgentKind.pi, "ssh", "ssh"),
        (.claudeCode, "node.exe", "node"),
        (.claudeCode, "zsh.exe", "zsh"),
        (.claudeCode, "bash.exe", "bash"),
        (.claudeCode, "python3.exe", "python3"),
        (.claudeCode, "nvim.exe", "nvim"),
        (.claudeCode, "node", "claude"),
    ])
    func misconfiguredCandidateCannotVerifyNonAgents(kind: AgentKind, comm: String, candidate: String) {
        #expect(!AgentPromptGate.foregroundCommandMatches(kind, observedCommand: comm, configuredBinaryCandidate: { candidate }))
    }

    @Test(
        arguments: [
            (AgentForegroundIncarnation(pid: 100, startedAt: 1_000), AgentForegroundIncarnation(pid: 200, startedAt: 2_000)),
            (nil, AgentForegroundIncarnation(pid: 200, startedAt: 2_000)),
            (AgentForegroundIncarnation(pid: 100, startedAt: 1_000), nil),
            (AgentForegroundIncarnation(pid: 100, startedAt: 1_000), AgentForegroundIncarnation(pid: 100, startedAt: 9_000)),
        ] as [(AgentForegroundIncarnation?, AgentForegroundIncarnation?)])
    func mismatchedGenerationsDecline(verified: AgentForegroundIncarnation?, observed: AgentForegroundIncarnation?) {
        #expect(
            verdict(kind: .claudeCode, comm: "claude", verifiedGeneration: verified, observedGeneration: observed)
                == .unavailable(.noVerifiedAgent))
    }

    @Test(
        arguments: [
            (AgentKind.codex, "codex-aarch64-apple-darwin", nil, true),
            (AgentKind.openCode, "opencode-darwin-arm64", nil, true),
            (AgentKind.claudeCode, "2.1.214", nil, true),
            (AgentKind.codex, "2.1.214", nil, false),
            (AgentKind.pi, "2.1.214", nil, false),
            (AgentKind.openCode, "2.1.214", nil, false),
            (AgentKind.claudeCode, "2.1.214a", nil, false),
            (AgentKind.claudeCode, ".214", nil, false),
            (AgentKind.claudeCode, "2.", nil, false),
            (AgentKind.claudeCode, "v2.1.214", nil, false),
            (AgentKind.claudeCode, "2-1-214", nil, false),
            (AgentKind.claudeCode, "214", nil, false),
            (AgentKind.claudeCode, "2..1", nil, false),
            (AgentKind.claudeCode, "1.2.\u{0663}", nil, false),
            (AgentKind.claudeCode, "..", nil, false),
            (AgentKind.claudeCode, "1.2a.3", nil, false),
            (AgentKind.pi, "pi", nil, true),
            (AgentKind.pi, "pip", nil, false),
            (AgentKind.pi, "ping", nil, false),
            (AgentKind.claudeCode, "2.1.300-beta", "2.1.300-beta", true),
            (AgentKind.pi, "pi-custom", "pi-custom", true),
            (AgentKind.pi, "pi-agent-launch", "pi-agent-launcher-custom", true),
            (AgentKind.pi, "pi-agent", "pi-agent-launcher-custom", false),
            (AgentKind.claudeCode, "claude.exe", nil, true),
            (AgentKind.claudeCode, "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe", nil, true),
            (AgentKind.codex, "codex.exe", nil, true),
            (AgentKind.openCode, "opencode.exe", nil, true),
            (AgentKind.pi, "pi.exe", nil, true),
            (AgentKind.claudeCode, "claude.exe.exe", nil, false),
            (AgentKind.claudeCode, "my-agent.exe", "my-agent.exe", true),
            (AgentKind.claudeCode, "my-agent", "my-agent.exe", true),
            (AgentKind.claudeCode, "2.1.214.exe", nil, false),
            (AgentKind.claudeCode, "2.1.214.EXE", nil, false),
            (AgentKind.claudeCode, "my-long-agent.ex", "/opt/tools/my-long-agent.exe", true),
            (AgentKind.claudeCode, ".exe", nil, false),
            (AgentKind.generic, "muse", nil, true),
        ] as [(AgentKind, String, String?, Bool)])
    func foregroundCommandMatches(kind: AgentKind, command: String, candidate: String?, expected: Bool) {
        #expect(
            AgentPromptGate.foregroundCommandMatches(kind, observedCommand: command, configuredBinaryCandidate: { candidate }) == expected)
    }
}
