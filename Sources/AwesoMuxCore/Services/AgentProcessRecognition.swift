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
        // Claude Code: native installer executes version-named files (e.g. 2.1.214)
        // and suffixed launchers (claude-*), mirrored in AgentPromptGate.
        let rawName = ShellRecognition.basename(command).lowercased()
        if name == "claude" || name.hasPrefix("claude-") || isBareVersionName(rawName) {
            return .claudeCode
        }
        // Generic coding agents (Muse, Cursor, Windsurf, Aider, Factory Droid,
        // Amp, Qwen, Kimi, Kilo, Roo, Cline, Copilot, Gemini, Goose, etc.).
        // One bucket `generic` covers all CLIs not otherwise matched; adding a
        // new generic CLI is one string in this list. Authoritative so a stray
        // "claude code" in scrollback cannot hijack a live generic pane, and
        // vice-versa via the same reclaim gate.
        if isGenericAgentCommand(name) {
            return .generic
        }
        return nil
    }

    private static func isGenericAgentCommand(_ name: String) -> Bool {
        // Direct binaries and their suffixed variants. Keep the list explicit;
        // heuristic fallback would mis-tag builds/tests mentioning these words.
        let genericPrefixes = [
            "muse", "muse-bin",
            "cursor-agent", "cursor",
            "windsurf", "windsurf-",
            "aider", "aider-",
            "droid", "droid-",
            "amp", "amp-",
            "qwen", "qwen-",
            "kimi", "kimi-",
            "kilo", "kilo-",
            "roo", "roo-",
            "cline", "cline-",
            "copilot", "copilot-",
            "gemini", "gemini-",
            "goose", "goose-",
            "continue", "continue-",
            "zed", "zed-",
            "warp", "warp-",
            "crush", "crush-",
            "kiro", "kiro-",
            "codebuddy", "codebuddy-",
            "qoder", "qoder-",
            "agy", "agy-",
            "shai", "shai-",
            "tabnine", "tabnine-",
            "openclaw", "openclaw-",
            "trae", "trae-",
            "augment", "augment-",
            "codebuff", "codebuff-",
        ]
        for prefix in genericPrefixes {
            if prefix.hasSuffix("-") {
                if name.hasPrefix(prefix) { return true }
            } else {
                if name == prefix || name.hasPrefix(prefix + "-") { return true }
            }
        }
        return false
    }

    private static func isBareVersionName(_ name: String) -> Bool {
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }
}
