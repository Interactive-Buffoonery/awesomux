import Testing

@testable import AwesoMuxCore

@Suite("Agent prompt gate")
struct AgentPromptGateTests {
    /// A matching pair by default so every pre-existing test — none of which
    /// are about generation binding — keeps exercising exactly the behavior
    /// it names. Tests for the generation check itself override these.
    private static let defaultGeneration = AgentForegroundIncarnation(pid: 4242, startedAt: 1_000)

    private func verdict(
        kind: AgentKind,
        state: AgentState = .waiting,
        enabled: Bool = true,
        comm: String? = nil,
        binaryCandidate: String? = nil,
        verifiedGeneration: AgentForegroundIncarnation? = defaultGeneration,
        observedGeneration: AgentForegroundIncarnation? = defaultGeneration
    ) -> AgentPromptGate.Verdict {
        AgentPromptGate.verdict(
            agentKind: kind,
            agentState: state,
            isIntegrationEnabled: { _ in enabled },
            observedForegroundCommand: comm,
            verifiedWaitingForegroundGeneration: verifiedGeneration,
            observedForegroundGeneration: observedGeneration,
            configuredBinaryCandidate: { binaryCandidate }
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
    func verifiedProviders(kind: AgentKind, comm: String) {
        #expect(verdict(kind: kind, comm: comm) == .verified(kind))
    }

    @Test("Claude Code's native installer verifies via its version-named binary")
    func nativeInstallClaudeVerifies() {
        // Measured live: `claude` symlinks to ~/.local/share/claude/versions/
        // 2.1.214, and p_comm names the resolved file, so the observed comm is
        // the bare semver.
        #expect(verdict(kind: .claudeCode, comm: "2.1.214") == .verified(.claudeCode))
    }

    @Test(
        "shell and grok never verify, even waiting with a provider-looking foreground",
        arguments: [AgentKind.shell, .grok]
    )
    func unsupportedKindsDecline(kind: AgentKind) {
        #expect(verdict(kind: kind, comm: "claude") == .unavailable(.noVerifiedAgent))
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
            observedForegroundCommand: kind == .claudeCode ? "claude" : "codex",
            verifiedWaitingForegroundGeneration: Self.defaultGeneration,
            observedForegroundGeneration: Self.defaultGeneration
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
            verdict(kind: .claudeCode, state: state, comm: "claude")
                == .unavailable(.agentNotReceptive(.claudeCode))
        )
    }

    @Test("absent foreground evidence fails closed")
    func nilCommDeclines() {
        #expect(verdict(kind: .codex, comm: nil) == .unavailable(.noVerifiedAgent))
    }

    @Test(
        "a waiting agent with a non-provider foreground process declines",
        arguments: ["zsh", "vim", "less", "htop", "node", "python3"]
    )
    func foregroundMismatchDeclines(comm: String) {
        #expect(verdict(kind: .claudeCode, comm: comm) == .unavailable(.noVerifiedAgent))
    }

    // MARK: - Foreground-generation binding (INT-569 follow-up)
    //
    // `.waiting` can be synthesized from bare process-name recognition or
    // scraped viewport text — neither proves the CURRENT foreground process
    // ever earned it via a real hook. These prove the gate now binds
    // `.waiting` evidence to the exact (pid, start time) a trusted hook last
    // confirmed, and rejects anything that doesn't match the live process.

    @Test("a same-provider relaunch's fresh incarnation is rejected until its own hook confirms it")
    func relaunchedProcessDeclinesDespiteMatchingComm() {
        // The stale `.waiting` (and its trusted generation) came from a
        // process that has since exited; a new same-named process is now
        // foreground with a different pid/start time — exactly the
        // same-provider-relaunch spoof window this closes.
        let staleGeneration = AgentForegroundIncarnation(pid: 100, startedAt: 1_000)
        let relaunchedGeneration = AgentForegroundIncarnation(pid: 200, startedAt: 2_000)
        #expect(
            verdict(
                kind: .claudeCode,
                comm: "claude",
                verifiedGeneration: staleGeneration,
                observedGeneration: relaunchedGeneration
            ) == .unavailable(.noVerifiedAgent)
        )
    }

    @Test("no trusted hook has ever confirmed waiting for this pane")
    func absentTrustedGenerationDeclines() {
        // Only a synthesized/scraped `.waiting` exists (e.g.
        // `detectAgentExitedToShell`'s process-recognition fast path) — no
        // real hook ever stamped a trusted generation.
        #expect(
            verdict(
                kind: .claudeCode,
                comm: "claude",
                verifiedGeneration: nil,
                observedGeneration: AgentForegroundIncarnation(pid: 200, startedAt: 2_000)
            ) == .unavailable(.noVerifiedAgent)
        )
    }

    @Test("no live foreground process evidence declines even with a trusted generation on record")
    func absentObservedGenerationDeclines() {
        #expect(
            verdict(
                kind: .claudeCode,
                comm: "claude",
                verifiedGeneration: AgentForegroundIncarnation(pid: 100, startedAt: 1_000),
                observedGeneration: nil
            ) == .unavailable(.noVerifiedAgent)
        )
    }

    @Test("the same live process that earned a trusted waiting hook is still verified")
    func sameProcessIncarnationVerifies() {
        // The process never relaunched — pid and start time are unchanged —
        // so the earlier hook's trust still legitimately applies.
        let generation = AgentForegroundIncarnation(pid: 4242, startedAt: 1_000)
        #expect(
            verdict(
                kind: .claudeCode,
                comm: "claude",
                verifiedGeneration: generation,
                observedGeneration: generation
            ) == .verified(.claudeCode)
        )
    }

    @Test("incarnations with the same pid but a different start time are rejected")
    func pidReuseWithDifferentStartTimeDeclines() {
        // A pid can be recycled by the OS; start time is what actually
        // distinguishes the exited process from its replacement.
        #expect(
            verdict(
                kind: .claudeCode,
                comm: "claude",
                verifiedGeneration: AgentForegroundIncarnation(pid: 100, startedAt: 1_000),
                observedGeneration: AgentForegroundIncarnation(pid: 100, startedAt: 9_000)
            ) == .unavailable(.noVerifiedAgent)
        )
    }

    @Test("the configured binary candidate is not consulted for a non-receptive agent")
    func candidateNotConsultedWhenNotReceptive() {
        let verdict = AgentPromptGate.verdict(
            agentKind: .codex,
            agentState: .running,
            isIntegrationEnabled: { _ in true },
            observedForegroundCommand: "codex",
            configuredBinaryCandidate: {
                Issue.record("non-receptive agents must decline before candidate lookup")
                return nil
            }
        )
        #expect(verdict == .unavailable(.agentNotReceptive(.codex)))
    }

    // MARK: - foregroundCommandMatches

    @Test("suffixed launcher binaries match by provider prefix")
    func suffixedLaunchersMatch() {
        #expect(
            AgentPromptGate.foregroundCommandMatches(
                .codex, observedCommand: "codex-aarch64-apple-darwin"
            ))
        #expect(
            AgentPromptGate.foregroundCommandMatches(
                .openCode, observedCommand: "opencode-darwin-arm64"
            ))
    }

    @Test("the bare-version pattern is scoped to Claude Code only")
    func versionPatternScopedToClaude() {
        #expect(AgentPromptGate.foregroundCommandMatches(.claudeCode, observedCommand: "2.1.214"))
        #expect(!AgentPromptGate.foregroundCommandMatches(.codex, observedCommand: "2.1.214"))
        #expect(!AgentPromptGate.foregroundCommandMatches(.pi, observedCommand: "2.1.214"))
        #expect(!AgentPromptGate.foregroundCommandMatches(.openCode, observedCommand: "2.1.214"))
    }

    @Test(
        "names that are not bare dotted versions do not match the version pattern",
        arguments: ["2.1.214a", ".214", "2.", "v2.1.214", "2-1-214", "214"]
    )
    func malformedVersionNamesDecline(name: String) {
        #expect(!AgentPromptGate.foregroundCommandMatches(.claudeCode, observedCommand: name))
    }

    @Test("pi requires an exact name, not a prefix")
    func piExactOnly() {
        #expect(AgentPromptGate.foregroundCommandMatches(.pi, observedCommand: "pi"))
        #expect(!AgentPromptGate.foregroundCommandMatches(.pi, observedCommand: "pip"))
        #expect(!AgentPromptGate.foregroundCommandMatches(.pi, observedCommand: "ping"))
    }

    @Test("a configured binary basename matches exactly for any supported kind")
    func configuredCandidateMatches() {
        #expect(
            AgentPromptGate.foregroundCommandMatches(
                .claudeCode,
                observedCommand: "2.1.300-beta",
                configuredBinaryCandidate: { "2.1.300-beta" }
            ))
        #expect(
            AgentPromptGate.foregroundCommandMatches(
                .pi,
                observedCommand: "pi-custom",
                configuredBinaryCandidate: { "pi-custom" }
            ))
    }

    @Test("a truncated observation matches a longer configured basename by prefix")
    func truncatedObservationMatchesCandidate() {
        // Kernel process names truncate; a 15+-char observation may be the
        // prefix of the configured basename.
        #expect(
            AgentPromptGate.foregroundCommandMatches(
                .pi,
                observedCommand: "pi-agent-launch",
                configuredBinaryCandidate: { "pi-agent-launcher-custom" }
            ))
        // Short observations never prefix-match — that would let "p" match.
        #expect(
            !AgentPromptGate.foregroundCommandMatches(
                .pi,
                observedCommand: "pi-agent",
                configuredBinaryCandidate: { "pi-agent-launcher-custom" }
            ))
    }

    @Test(
        "a configured binary_path naming a shell, interpreter, or TUI never matches",
        arguments: ["node", "zsh", "vim", "less", "htop", "python3", "tmux", "ssh"]
    )
    func misconfiguredCandidateCannotVerifyNonAgents(comm: String) {
        // A misconfigured binary_path (e.g. pointing at /bin/zsh) must not
        // open the gate to exactly the processes it exists to protect.
        #expect(
            !AgentPromptGate.foregroundCommandMatches(
                .pi,
                observedCommand: comm,
                configuredBinaryCandidate: { comm }
            ))
    }

    @Test(
        "the version pattern requires non-empty ASCII-digit components",
        arguments: ["2..1", "1.2.\u{0663}", "..", "1.2a.3"]
    )
    func versionPatternIsStrict(name: String) {
        #expect(!AgentPromptGate.foregroundCommandMatches(.claudeCode, observedCommand: name))
    }

    @Test("wrapper interpreters never match, even with a claude candidate configured")
    func wrapperInterpreterDeclines() {
        // npm-installed Claude Code foregrounds as `node`; indistinguishable
        // from a raw-mode node REPL, so it must stay a false negative.
        #expect(
            !AgentPromptGate.foregroundCommandMatches(
                .claudeCode,
                observedCommand: "node",
                configuredBinaryCandidate: { "claude" }
            ))
    }
}
