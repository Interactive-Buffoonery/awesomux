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
}
