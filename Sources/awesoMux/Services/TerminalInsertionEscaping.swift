/// Shell-escapes text inserted into a live terminal buffer from outside the
/// keyboard (clipboard paste, external drag-and-drop). Shared by
/// `GhosttyClipboardBridge`'s paste path and `GhosttySurfaceDragAndDrop`'s
/// drag path so the two "content arrived from the pasteboard" surfaces can't
/// silently drift onto different escaping rules.
///
/// Based on Ghostty's `Ghostty.Shell.escape` (`vendor/ghostty/macos/Sources/Ghostty/Ghostty.Shell.swift`),
/// with two deliberate divergences:
///
/// - `\n`/`\r` are ANSI-C-quoted (`$'\n'`/`$'\r'`) instead of backslash-escaped.
///   A backslash immediately followed by a raw newline is a POSIX shell line
///   *continuation*, not an escaped literal newline — upstream's approach
///   (and this file's own prior approach) silently glues the two halves of
///   the token onto one line and drops the newline, which is a wrong-file
///   correctness bug for macOS filenames that legally contain a newline
///   byte. `$'...'` is a self-contained quoted word that both bash and zsh
///   concatenate correctly with the backslash-escaped text on either side
///   (verified: `eval`-ing `a$'\n'b` in both shells yields one argument,
///   the three bytes `a`, newline, `b` — matching the original filename
///   byte-for-byte).
/// - a token that still starts with `-` after escaping is prefixed with
///   `./`. Upstream doesn't guard this: a file literally named `-rf`,
///   dropped after the user has typed a command stem like `rm `, would
///   otherwise ride through as a bare flag-shaped argument. `./` forces it
///   to parse as an explicit relative path instead.
///
/// This is deliberately *not* full shell quoting (no quote-wrapping, no
/// handling of every POSIX metacharacter) — it mirrors Ghostty's own
/// backslash-per-character approach, which is scoped to "make a
/// paste/drop-inserted path or URL behave as a single token," not to build an
/// arbitrary shell command line.
enum TerminalInsertionEscaping {
    private static let escapeCharacters = Set("\\ ()[]{}<>\"'`!#$&;|*?\t")

    static func escape(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)

        for character in string {
            switch character {
            case "\n":
                result += "$'\\n'"
            case "\r":
                result += "$'\\r'"
            default:
                if escapeCharacters.contains(character) {
                    result.append("\\")
                }
                result.append(character)
            }
        }

        if result.hasPrefix("-") {
            result = "./" + result
        }

        return result
    }
}
