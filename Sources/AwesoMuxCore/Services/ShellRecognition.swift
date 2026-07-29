/// Shared login-shell name recognition. Extracted from INT-570's daemon GC so
/// both daemon idleness (`DaemonGCPlan.isIdle`) and the INT-217 quit-risk
/// liveness classifier use one shell set and one basename rule.
public enum ShellRecognition {
    /// Login shells we recognize as "idle at a prompt" when they have no
    /// children. A foreground process that is NOT one of these means real work
    /// is running (the user `exec`'d a command, or an agent process is live).
    public static let recognizedShells: Set<String> = [
        "zsh", "bash", "fish", "sh", "dash", "ksh", "csh", "tcsh", "nu",
        "pwsh", "xonsh", "elvish"
    ]

    /// Reduce a `comm`/argv0/path to a bare shell name: strip the directory and
    /// the leading `-` that marks a login shell's argv0 (e.g. `-zsh`).
    public static func basename(_ command: String) -> String {
        var name = command
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        if name.hasPrefix("-") {
            name.removeFirst()
        }
        return name
    }

    public static func isRecognizedShell(_ command: String) -> Bool {
        recognizedShells.contains(basename(command))
    }

    /// `basename`, lowercased, with a single trailing `.exe` removed — the form
    /// every provider-name comparison should match against.
    ///
    /// npm ships Claude Code as `…/@anthropic-ai/claude-code/bin/claude.exe`, so
    /// `p_comm` reads `claude.exe` on macOS while `ps -o comm` prints `claude`
    /// (ps reports argv0; `p_comm` reports the executed file). Measured live,
    /// where it was the sole reason a receptive agent was refused.
    ///
    /// It lives here, beside `basename`, because BOTH name→provider mappers call
    /// through this type: `AgentProcessRecognition` (which decides a pane is an
    /// agent at all) and `AgentPromptGate` (which decides staging is safe). A
    /// normalizer private to either one is guaranteed to drift from the other —
    /// it did, and the pane-identity side was the layer that ran first
    /// (multi-reviewer finding).
    ///
    /// Deliberately NOT folded into `basename`: `isRecognizedShell` and the
    /// quit-risk liveness classifier read raw names, and no macOS shell ships as
    /// `.exe`. Callers opt in.
    public static func normalizedCommandName(_ command: String) -> String {
        var name = basename(command).lowercased()
        if name.hasSuffix(".exe") {
            name.removeLast(4)
        }
        return name
    }
}
