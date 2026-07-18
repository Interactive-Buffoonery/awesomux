import Testing

@testable import AwesoMuxCore

@Suite("Agent prompt gate")
struct AgentPromptGateTests {
    private func verdict(
        kind: AgentKind,
        state: AgentState = .waiting,
        enabled: Bool = true,
        matches: Bool = true
    ) -> AgentPromptGate.Verdict {
        AgentPromptGate.verdict(
            agentKind: kind,
            agentState: state,
            isIntegrationEnabled: { _ in enabled },
            matchesForegroundExecutable: { _ in matches }
        )
    }

    @Test(
        "every supported provider verifies at a live waiting prompt",
        arguments: [
            (AgentKind.claudeCode, "claude"),
            (AgentKind.codex, "codex"),
            (AgentKind.pi, "pi"),
            (AgentKind.openCode, "opencode"),
        ]
    )
    func verifiedProviders(kind: AgentKind, expectedCommand: String) {
        let verdict = AgentPromptGate.verdict(
            agentKind: kind,
            agentState: .waiting,
            isIntegrationEnabled: { _ in true },
            matchesForegroundExecutable: { command in
                #expect(command == expectedCommand)
                return true
            }
        )
        #expect(verdict == .verified(kind))
    }

    @Test(
        "shell and grok never verify, even waiting with a matching foreground",
        arguments: [AgentKind.shell, .grok]
    )
    func unsupportedKindsDecline(kind: AgentKind) {
        #expect(verdict(kind: kind) == .unavailable(.noVerifiedAgent))
    }

    @Test(
        "consent-gated providers decline when their integration is disabled",
        arguments: [AgentKind.pi, .openCode]
    )
    func disabledConsentProvidersDecline(kind: AgentKind) {
        #expect(
            verdict(kind: kind, enabled: false)
                == .unavailable(.agentIntegrationDisabled(kind))
        )
    }

    @Test(
        "provider-managed hook providers do not consult integration consent",
        arguments: [AgentKind.claudeCode, .codex]
    )
    func trustedProvidersSkipConsent(kind: AgentKind) {
        var consentConsulted = false
        let verdict = AgentPromptGate.verdict(
            agentKind: kind,
            agentState: .waiting,
            isIntegrationEnabled: { _ in
                consentConsulted = true
                return false
            },
            matchesForegroundExecutable: { _ in true }
        )
        #expect(verdict == .verified(kind))
        #expect(!consentConsulted)
    }

    @Test(
        "every non-waiting state declines",
        arguments: AgentState.allCases.filter { $0 != .waiting }
    )
    func nonWaitingStatesDecline(state: AgentState) {
        #expect(
            verdict(kind: .claudeCode, state: state)
                == .unavailable(.agentNotReceptive(.claudeCode))
        )
    }

    @Test("a waiting agent with a mismatched foreground process declines")
    func foregroundMismatchDeclines() {
        #expect(
            verdict(kind: .codex, matches: false)
                == .unavailable(.noVerifiedAgent)
        )
    }

    @Test("the foreground probe is not consulted for unsupported kinds")
    func probeNotConsultedForUnsupportedKinds() {
        let verdict = AgentPromptGate.verdict(
            agentKind: .shell,
            agentState: .waiting,
            isIntegrationEnabled: { _ in true },
            matchesForegroundExecutable: { _ in
                Issue.record("unsupported kinds must decline before probing")
                return true
            }
        )
        #expect(verdict == .unavailable(.noVerifiedAgent))
    }

    @Test("the foreground probe is not consulted for a non-receptive agent")
    func probeNotConsultedWhenNotReceptive() {
        let verdict = AgentPromptGate.verdict(
            agentKind: .codex,
            agentState: .running,
            isIntegrationEnabled: { _ in true },
            matchesForegroundExecutable: { _ in
                Issue.record("non-receptive agents must decline before probing")
                return true
            }
        )
        #expect(verdict == .unavailable(.agentNotReceptive(.codex)))
    }

    @Test("grok and shell have no expected foreground command")
    func expectedCommandScope() {
        #expect(AgentPromptGate.expectedForegroundCommand(for: .grok) == nil)
        #expect(AgentPromptGate.expectedForegroundCommand(for: .shell) == nil)
    }
}
