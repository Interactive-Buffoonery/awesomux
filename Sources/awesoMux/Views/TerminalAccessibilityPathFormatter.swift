import AwesoMuxCore
import Foundation

enum TerminalAccessibilityPathFormatter {
    static let maximumPathLength = 80

    // Resolved once per process — the home directory can't change mid-run, so
    // rebuilding the URL on every format() call was pure waste. Canonical so the
    // prefix strip matches the canonicalized-at-ingest working directory under a
    // symlinked home (INT-498) — otherwise VoiceOver speaks the username.
    private static let homePath = WorkingDirectoryValidator.canonicalHomeDirectory

    /// Strips C0 control bytes (CR/LF/TAB/BEL/…) and DEL to spaces before a
    /// string is spoken by VoiceOver. A terminal-controlled cwd or title can
    /// carry any byte except `/` and NUL (OSC 7 / OSC 0/2), and raw control
    /// chars fragment the spoken string or ring the a11y client. Bidi-isolate
    /// handling is intentionally omitted to match the `compactTitle` house
    /// decision in AwesoMuxApp — isolates add spoken artifacts, not clarity.
    static func sanitizedForSpeech(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.map { scalar in
            (scalar.value < 0x20 || scalar.value == 0x7F) ? " " : scalar
        }))
    }

    static func format(_ path: String) -> String {
        let displayPath = abbreviatedHomePath(sanitizedForSpeech(path))
        let compactPath = compactDeepPath(displayPath)
        return cappedToMaximumLength(compactPath)
    }

    private static func abbreviatedHomePath(_ path: String) -> String {
        guard path == homePath || path.hasPrefix(homePath + "/") else {
            return path
        }

        let suffix = String(path.dropFirst(homePath.count))
        return suffix.isEmpty ? "~" : "~" + suffix
    }

    private static func compactDeepPath(_ path: String) -> String {
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.count > 3 else {
            return path
        }

        let prefix = path.hasPrefix("/") ? "/" : ""
        return prefix + components.prefix(1).joined()
            + "/.../"
            + components.suffix(2).joined(separator: "/")
    }

    // Front-truncates so the trailing, most-identifying portion of the path (the
    // leaf directory) survives — a screen-reader user disambiguates panes by the
    // leaf, not the prefix. Truncating from the front also collapses to a single
    // marker even when `compactDeepPath` already inserted one, so a deep-AND-long
    // path never reads "dot-dot-dot … dot-dot-dot".
    private static func cappedToMaximumLength(_ value: String) -> String {
        guard value.count > maximumPathLength else {
            return value
        }

        let marker = "..."
        guard maximumPathLength > marker.count else {
            return String(value.suffix(maximumPathLength))
        }

        let tailLength = maximumPathLength - marker.count
        return marker + String(value.suffix(tailLength))
    }
}
