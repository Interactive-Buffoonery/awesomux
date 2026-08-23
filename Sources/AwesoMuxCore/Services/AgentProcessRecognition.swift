import AwesoMuxBridgeProtocol
/// Recognizes foreground process names that identify a live agent CLI.
///
/// `ProcessLivenessProbe` reads macOS `p_comm`, not the full argv. That name is
/// short and may be a path basename or a suffixed launcher binary, so keep this
/// matching explicit instead of open-coding exact string comparisons at sampler
/// call sites.
public enum AgentProcessRecognition {
    public static func agentKind(forCommand command: String?) -> AgentKind? {
        guard let command else {
            return nil
        }

        // Same normalization the prompt gate uses: an npm-packaged launcher
        // observes as `codex.exe`, and a pane this mapper fails to tag stays
        // `.shell` — which the gate rejects at its FIRST guard, long before the
        // name matching it was fixed in. Both mappers must agree on what a
        // provider binary is called (multi-reviewer finding).
        let name = ShellRecognition.normalizedCommandName(command)
        if name == "codex" || name.hasPrefix("codex-") {
            return .codex
        }
        if name == "opencode" || name.hasPrefix("opencode-") {
            return .openCode
        }
        if name == "grok" || name.hasPrefix("grok-") {
            return .grok
        }
        // Exact basename only, mirroring AgentPromptGate's `.pi` arm so the two
        // mappers agree on what the provider binary is called. Pi ships no
        // sibling binaries, and a prefix arm here would claim unrelated
        // commands ("pip", "pianobar") as agent panes.
        if name == "pi" {
            return .pi
        }
        return nil
    }
}
