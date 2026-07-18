import Foundation

/// Verified-agent-prompt policy for document-pane handoff (INT-569).
///
/// Staged nudge text is safe at a cooked-mode shell prompt (no trailing
/// newline; the user presses Return) but dangerous in a raw-mode TUI, which
/// consumes injected bytes immediately. This gate therefore declines every
/// target that is not a verified, prompt-receptive agent surface. False
/// negatives (a real agent occasionally reading as unavailable) are
/// acceptable; false positives that stage bytes into a shell or non-agent
/// TUI are not.
///
/// One verdict drives the send-bar label, the enabled state, and the
/// click-time action, so UI wording can never claim a verified agent when
/// staging is unsafe. INT-582's provider-aware annotation handoff must route
/// through this same policy before staging text.
public enum AgentPromptGate {
    /// The v1 provider scope modeled by INT-569. Grok is deliberately
    /// excluded until the issue's provider list grows.
    static let supportedProviders: Set<AgentKind> = [
        .claudeCode, .codex, .pi, .openCode,
    ]

    public enum Verdict: Hashable, Sendable {
        case verified(AgentKind)
        case unavailable(DocumentNudgeUnavailableReason)
    }

    /// Providers whose runtime status events are consent-gated by
    /// `agent_integrations.<provider>.enabled` (the file-drop allowlist).
    /// Claude Code and Codex hook events are provider-managed and trusted
    /// once installed — mirrors `AgentRuntimeConsent.enabledFileDropSources`,
    /// so the pane state this gate reads is only hook-authoritative for these
    /// two providers when their toggle is on.
    static func requiresIntegrationConsent(_ kind: AgentKind) -> Bool {
        kind == .pi || kind == .openCode
    }

    /// Expected foreground `p_comm` for a live provider process; nil for
    /// kinds this gate never verifies. Exact-match only, on the same probe
    /// seam the document nudge's SSH check uses.
    // ponytail: exact names. An npm-installed Claude Code runs under a `node`
    // comm and suffixed Codex launchers (`codex-aarch64-…`) won't match —
    // both decline (false negative, the safe direction). Extend the probe
    // seam to prefix matching if real installs surface these.
    static func expectedForegroundCommand(for kind: AgentKind) -> String? {
        switch kind {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .pi: "pi"
        case .openCode: "opencode"
        case .grok, .shell: nil
        }
    }

    /// - Parameters:
    ///   - agentKind: the target pane's tracked provider identity.
    ///   - agentState: the target pane's combined display state
    ///     (`TerminalPane.agentState`).
    ///   - isIntegrationEnabled: policy-free settings lookup; consulted only
    ///     for consent-gated providers.
    ///   - matchesForegroundExecutable: live foreground probe. Must return
    ///     true ONLY for a positive `.matching` observation so unknown
    ///     evidence fails closed.
    public static func verdict(
        agentKind: AgentKind,
        agentState: AgentState,
        isIntegrationEnabled: (AgentKind) -> Bool,
        matchesForegroundExecutable: (String) -> Bool
    ) -> Verdict {
        guard supportedProviders.contains(agentKind),
            let expectedCommand = expectedForegroundCommand(for: agentKind)
        else {
            return .unavailable(.noVerifiedAgent)
        }
        if requiresIntegrationConsent(agentKind), !isIntegrationEnabled(agentKind) {
            return .unavailable(.agentIntegrationDisabled(agentKind))
        }
        // `.waiting` is the hook-driven "turn ended, agent at its prompt"
        // state and the only receptive one. `.needsAttention` is deliberately
        // not receptive: staged text could answer a pending permission
        // prompt instead of landing in the composer.
        guard agentState == .waiting else {
            return .unavailable(.agentNotReceptive(agentKind))
        }
        // Durable pane state can outlive the process that reported it (Codex
        // and OpenCode emit no trusted quit signal), so also require the live
        // foreground process to be the provider binary. A bare shell or a
        // raw-mode TUI in the foreground fails this and declines.
        // ponytail: `.waiting` and the comm match are independent snapshots —
        // a same-provider relaunch can pass during its seconds-wide startup
        // window until its first hook event lands. The receiver is still the
        // provider binary, never a shell; generation-tagged prompt evidence
        // is the upgrade path if that window ever bites (INT-582 candidate).
        guard matchesForegroundExecutable(expectedCommand) else {
            return .unavailable(.noVerifiedAgent)
        }
        return .verified(agentKind)
    }
}
