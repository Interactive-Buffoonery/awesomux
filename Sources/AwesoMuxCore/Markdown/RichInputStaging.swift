import Foundation

/// Pure logic for the multiline rich-input composer: sanitizing composer text
/// before it is staged into a live terminal pane, and deciding how the Return
/// key behaves in the editor.
///
/// Kept free of AppKit/SwiftUI so the security-relevant sanitization and the
/// key-handling rule are unit-testable without a UI host.
public enum RichInputStaging {
    /// Sanitizes free-form composer text before it is staged into a live PTY.
    ///
    /// The staged text is delivered through libghostty's paste path
    /// (`ghostty_surface_text` → `completeClipboardPaste(_, allow_unsafe: true)`),
    /// which intentionally skips libghostty's own "does this paste try to break
    /// out of its bracketed-paste frame" check. A composer can hold anything the
    /// user pasted into it, so we strip terminal control bytes here: an embedded
    /// `ESC[201~` — or any escape sequence — must not be able to close the paste
    /// early and inject commands into the shell/agent.
    ///
    /// We strip C0/C1/DEL controls (the ESC/CSI bytes) and bidi override/isolate
    /// formatting (which reorders the visual terminal line — spoofing), matching
    /// the app's title sanitizer, while PRESERVING other format characters such
    /// as ZWJ so emoji sequences survive. Newlines and tabs are the whole point
    /// of a multi-line prompt, so they are kept; a lone CR (and the CR of a CRLF)
    /// is normalized to LF; trailing newlines are trimmed so staging never leaves
    /// a stray blank line ahead of the Return the user still presses to submit.
    public static func stagedPayload(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var iterator = text.unicodeScalars.makeIterator()
        var pending = iterator.next()
        while let scalar = pending {
            pending = iterator.next()
            switch scalar {
            case "\n", "\t":
                out.append(scalar)
            case "\r":
                out.append("\n")
                if pending == "\n" { pending = iterator.next() }
            default:
                if isStrippable(scalar) { continue }
                out.append(scalar)
            }
        }
        var result = String(out)
        while result.hasSuffix("\n") { result.removeLast() }
        return result
    }

    /// Characters that must not reach the PTY as staged paste content.
    private static func isStrippable(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        // C0 (except \n/\t, handled by the caller), DEL, and C1: these carry the
        // ESC/CSI bytes, including the ESC that could close a bracketed paste
        // early and break out into command execution.
        if value < 0x20 || (0x7F...0x9F).contains(value) { return true }
        // Bidi override/isolate formatting — PTY-safe but visually reorders the
        // line in the terminal. Other format chars (ZWJ, bidi marks) are kept.
        switch value {
        case 0x202A...0x202E, 0x2066...0x2069:
            return true
        default:
            return false
        }
    }

    public enum ReturnKeyOutcome: Equatable {
        /// Stage the composed text into the target pane.
        case send
        /// Insert a soft newline into the editor.
        case insertNewline
    }

    /// Decides what a Return keypress does in the composer: plain Return stages
    /// the text (chat-app "Enter to send"); Shift-Return or Option-Return inserts
    /// a newline. The caller derives `shift`/`option` from
    /// `NSEvent.modifierFlags.contains(...)`, which is inherently keypad-safe —
    /// keypad Enter carries `.numericPad`, but `.contains` is a subset test that
    /// never mistakes it for `.shift`/`.option`, so no flag subtraction is needed.
    public static func returnKeyOutcome(shift: Bool, option: Bool) -> ReturnKeyOutcome {
        (shift || option) ? .insertNewline : .send
    }
}
