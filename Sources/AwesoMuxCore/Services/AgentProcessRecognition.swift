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

        let name = ShellRecognition.basename(command).lowercased()
        if name == "codex" || name.hasPrefix("codex-") {
            return .codex
        }
        if name == "opencode" || name.hasPrefix("opencode-") {
            return .openCode
        }
        if name == "grok" || name.hasPrefix("grok-") {
            return .grok
        }
        return nil
    }
}
