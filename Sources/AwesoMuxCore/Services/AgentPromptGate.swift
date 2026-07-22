import AwesoMuxBridgeProtocol
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

/// Identity of one foreground-process incarnation, observed as (pid, start
/// time). Mirrors `AmxDaemonIncarnation`'s pid+createdAt shape for the same
/// reason: a relaunch of the same-named binary gets a new pid and a new start
/// time, so comparing incarnations tells "still the process we verified"
/// from "a same-name replacement" without trusting a bare comm-name match
/// alone. Used to bind `AgentPromptGate.verdict`'s `.waiting` evidence to the
/// exact process a real hook confirmed it against (INT-569 follow-up).
///
/// `startedAt`'s unit is an opaque, source-defined tick (AMX daemon epoch
/// seconds for a bridged pane, local `proc_pidinfo` epoch MICROSECONDS for a
/// non-bridged one — see `ProcessLivenessProbe.processStartTime`). Compare
/// for exact equality only, within the same source's values; never for
/// ordering or duration math across sources.
public struct AgentForegroundIncarnation: Equatable, Sendable {
    public let pid: Int
    public let startedAt: Int

    public init(pid: Int, startedAt: Int) {
        self.pid = pid
        self.startedAt = startedAt
    }
}

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

    /// - Parameters:
    ///   - agentKind: the target pane's tracked provider identity.
    ///   - agentState: the target pane's combined display state
    ///     (`TerminalPane.agentState`).
    ///   - isIntegrationEnabled: policy-free settings lookup; consulted only
    ///     for consent-gated providers.
    ///   - observedForegroundCommand: the live foreground process name
    ///     (`p_comm`) of the target terminal, or nil when no evidence is
    ///     available. Nil fails closed.
    ///   - verifiedWaitingForegroundGeneration: the foreground-process
    ///     incarnation observed at the moment a genuine provider hook last
    ///     confirmed `.waiting` for this pane, or nil if no hook has ever done
    ///     so. Never set by process-recognition or visible-text synthesis —
    ///     see `GhosttySurfaceTerminalEvents`.
    ///   - observedForegroundGeneration: the CURRENT foreground-process
    ///     incarnation, sampled fresh at the same moment as
    ///     `observedForegroundCommand`. Nil fails closed.
    ///   - configuredBinaryCandidate: symlink-resolved basename of the
    ///     provider's configured `binary_path`, when set; consulted only
    ///     after the earlier checks pass.
    public static func verdict(
        agentKind: AgentKind,
        agentState: AgentState,
        isIntegrationEnabled: (AgentKind) -> Bool,
        observedForegroundCommand: String?,
        verifiedWaitingForegroundGeneration: AgentForegroundIncarnation? = nil,
        observedForegroundGeneration: AgentForegroundIncarnation? = nil,
        configuredBinaryCandidate: () -> String? = { nil }
    ) -> Verdict {
        guard supportedProviders.contains(agentKind) else {
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
        // `.waiting` alone is not proof a real hook ever fired: it can also be
        // synthesized from bare process-name recognition the instant a
        // same-named process becomes foreground (`detectAgentExitedToShell`),
        // or scraped from viewport text — neither proves THIS process
        // incarnation ever reached a real, receptive prompt. A same-provider
        // relaunch would pass a comm-name check alone during its own
        // seconds-wide startup window (a splash screen or onboarding TUI that
        // consumes injected bytes), before its first genuine hook lands.
        // Only a trusted hook (`applyAgentRuntimeEvent`) stamps
        // `verifiedWaitingForegroundGeneration`, tied to the exact (pid, start
        // time) observed at that moment — a relaunch gets a fresh pid/start
        // time immediately, so requiring an exact match against the CURRENT
        // foreground incarnation rejects both a stale generation (old process
        // already exited) and a synthesized one (no trusted generation was
        // ever recorded).
        guard
            let verifiedWaitingForegroundGeneration,
            let observedForegroundGeneration,
            verifiedWaitingForegroundGeneration == observedForegroundGeneration
        else {
            return .unavailable(.noVerifiedAgent)
        }
        // Durable pane state can outlive the process that reported it (Codex
        // and OpenCode emit no trusted quit signal), so also require the live
        // foreground process to look like the provider binary. A bare shell
        // or a raw-mode TUI in the foreground fails this and declines.
        guard
            let observedForegroundCommand,
            foregroundCommandMatches(
                agentKind,
                observedCommand: observedForegroundCommand,
                configuredBinaryCandidate: configuredBinaryCandidate
            )
        else {
            return .unavailable(.noVerifiedAgent)
        }
        return .verified(agentKind)
    }

    /// Whether a live foreground `p_comm` is positive evidence for the
    /// provider binary. `p_comm` names the RESOLVED executable file, not the
    /// invoked symlink — a native-installed Claude Code (`claude` ->
    /// `~/.local/share/claude/versions/2.1.214`) reads as the bare version
    /// string, measured live on a real session.
    ///
    /// Matching stays deny-by-default: exact provider names, the provider's
    /// suffixed-launcher prefixes, the bare-version pattern for Claude Code
    /// only, and the operator-configured binary basename. Wrapper
    /// interpreters are deliberately NOT accepted — an npm-installed Claude
    /// Code foregrounds as `node`, and `node` alone is indistinguishable
    /// from a raw-mode node REPL, exactly what this gate must never inject
    /// into. That install flavor stays a false negative until the probe can
    /// read argv; `binary_path` config is the operator escape hatch.
    static func foregroundCommandMatches(
        _ kind: AgentKind,
        observedCommand: String,
        configuredBinaryCandidate: () -> String? = { nil }
    ) -> Bool {
        let name = ShellRecognition.basename(observedCommand).lowercased()
        guard !name.isEmpty else { return false }

        switch kind {
        case .claudeCode:
            if name == "claude" || name.hasPrefix("claude-") || isBareVersionName(name) {
                return true
            }
        case .codex:
            if name == "codex" || name.hasPrefix("codex-") {
                return true
            }
        case .openCode:
            if name == "opencode" || name.hasPrefix("opencode-") {
                return true
            }
        case .pi:
            if name == "pi" {
                return true
            }
        case .grok, .shell:
            return false
        }

        // Operator-configured basenames extend matching, but never to names
        // positively known to be shells, interpreters, or common raw-mode
        // TUIs — a misconfigured binary_path must not open the gate to
        // exactly the processes it exists to protect.
        guard !ShellRecognition.recognizedShells.contains(name),
            !knownNonAgentForegrounds.contains(name),
            let candidate = configuredBinaryCandidate()?.lowercased(), !candidate.isEmpty
        else {
            return false
        }
        // The kernel's process name buffer truncates long names, so a long
        // configured basename may only be observable as its prefix.
        return name == candidate || (name.count >= 15 && candidate.hasPrefix(name))
    }

    /// Interpreters and raw-mode TUIs that must never satisfy the
    /// configured-binary escape hatch, on top of `ShellRecognition`'s shell
    /// set. Deny-only list: absence here never grants a match.
    private static let knownNonAgentForegrounds: Set<String> = [
        "node", "bun", "deno", "python", "python3", "ruby", "perl",
        "vim", "nvim", "vi", "emacs", "nano", "less", "more",
        "htop", "top", "tmux", "screen", "ssh",
    ]

    /// `2.1.214`-shaped: non-empty dot-separated runs of ASCII digits, with
    /// at least one dot. Only Claude Code's native installer is known to
    /// execute version-named files; scoped to that kind at the call site.
    private static func isBareVersionName(_ name: String) -> Bool {
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }
}
