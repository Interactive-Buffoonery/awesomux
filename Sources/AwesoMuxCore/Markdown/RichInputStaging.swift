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
    /// early and inject commands into the shell/agent. This mirrors the
    /// control-character stripping the nudge path already applies to file paths.
    ///
    /// Newlines and tabs are the whole point of a multi-line prompt, so they are
    /// preserved; a lone CR (and the CR of a CRLF) is normalized to LF; trailing
    /// newlines are trimmed so staging never leaves a stray blank line ahead of
    /// the Return the user still presses to submit.
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
                if !CharacterSet.controlCharacters.contains(scalar) {
                    out.append(scalar)
                }
            }
        }
        var result = String(out)
        while result.hasSuffix("\n") { result.removeLast() }
        return result
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
