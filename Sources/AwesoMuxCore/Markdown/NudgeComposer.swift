import Foundation

/// Composes the plain-English nudge text injected into the document's associated
/// terminal when the user taps the nudge button in a document pane's title bar.
///
/// The nudge is staged (no trailing newline) — the user sees it at their prompt
/// and can review or edit it before pressing Return to send. This keeps the
/// write-to-agent loop deliberate: the user is the final decision point.
public enum NudgeComposer {
    public static func text(displayPath: String) -> String {
        // POSIX single-quote the path. The nudge is staged into a live PTY; if the
        // target happens to be a shell (agent detection isn't reliable yet) and the
        // user presses Return, an unquoted filename like `notes; rm -rf ~ #.md` would
        // run as a command. Single-quoting makes the path an inert literal in any
        // POSIX shell, while still reading clearly as a path to an agent. (Control
        // chars are separately stripped upstream in resolveDisplayPath.)
        "Address my review annotations in \(shellSingleQuoted(displayPath)). "
            + "Annotations are HTML comment markers: <!-- USER COMMENT N: … --> or "
            + "<!-- AMX id=… by=… …: … -->. A marker right after <mark>highlighted</mark> text "
            + "is a request about that span; the single AMX marker on its own line is the note "
            + "about the whole document. intent=replace carries suggested replacement text for the span; "
            + "intent=delete asks you to remove it. When you've handled one: for AMX markers, "
            + "set status=resolved inside the marker (keep it so I can verify) or remove the "
            + "<mark> wrapper and marker; for USER COMMENT markers, remove the wrapper and "
            + "marker. Inline annotations can have replies using "
            + "<!-- AMX re=<id> by=<provider>: note --> and your provider id "
            + "(claude-code, codex, pi, or opencode); the document note has no replies."
    }

    /// Wraps a string in POSIX single quotes, escaping any embedded single quote via
    /// the standard `'\''` close-escape-reopen idiom. Safe for any shell input.
    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
