import Foundation

// MARK: - AgentPluginDiagnostics

/// A capped, redacted capture of a failed CLI/RPC op, surfaced behind an
/// expandable disclosure on the settings card. The contract (§3) requires a
/// present-but-errored op to surface its stderr verbatim; this carries that text
/// while keeping it bounded (so a runaway binary cannot flood the UI) and
/// home-redacted (so a screenshot of the disclosure does not leak the username).
struct AgentPluginDiagnostics: Equatable, Sendable {
    var executablePath: String
    var args: [String]
    var exitCode: Int32?
    /// Redacted ($HOME → ~) and capped stdout/stderr.
    var stdout: String
    var stderr: String
    var summary: String

    /// Per-stream caps. Long enough to carry a real stack/error, short enough to
    /// never dominate the card.
    static let maxLines = 40
    static let maxCharacters = 4_000

    init(
        executablePath: String,
        args: [String],
        exitCode: Int32?,
        rawStdout: String,
        rawStderr: String,
        summary: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.executablePath = Self.redact(executablePath, homeDirectory: homeDirectory)
        self.args = args.map { Self.redact($0, homeDirectory: homeDirectory) }
        self.exitCode = exitCode
        self.stdout = Self.capLeadingAndTrailing(Self.redact(rawStdout, homeDirectory: homeDirectory))
        self.stderr = Self.capTrailing(Self.redact(rawStderr, homeDirectory: homeDirectory))
        self.summary = Self.redact(summary, homeDirectory: homeDirectory)
    }

    /// Collapse the user's home prefix to `~` so a shared diagnostic does not
    /// carry the account name. Anchored on the home path (not a bare username
    /// match) to avoid mangling unrelated text.
    static func redact(_ value: String, homeDirectory: URL) -> String {
        let home = homeDirectory.path
        guard !home.isEmpty, home != "/" else {
            return value
        }
        // Anchor on the directory boundary: an unanchored replace of the bare
        // home would mangle sibling paths that merely share the prefix
        // (`/Users/example2/log` → `~2/log`). Collapse `<home>/` to `~/` first, then
        // map a bare `<home>` token (no trailing component) to `~`.
        let homeSlash = home.hasSuffix("/") ? home : home + "/"
        var result = value.replacingOccurrences(of: homeSlash, with: "~/")
        if result == home {
            return "~"
        }

        var searchStart = result.startIndex
        while searchStart < result.endIndex,
              let range = result.range(of: home, range: searchStart ..< result.endIndex) {
            let afterHome = range.upperBound
            let isBoundary: Bool
            if afterHome == result.endIndex {
                isBoundary = true
            } else {
                let next = result[afterHome]
                // A bare home token is a boundary when it is not followed by `/`
                // (handled above) and does not continue the final path component
                // (e.g. `/Users/example2/...` must not collapse to `~2/...`).
                isBoundary = next != "/" && !isPathComponentContinuationCharacter(next)
            }

            if isBoundary {
                let lowerBoundOffset = result.distance(from: result.startIndex, to: range.lowerBound)
                result.replaceSubrange(range, with: "~")
                searchStart = result.index(
                    result.startIndex,
                    offsetBy: lowerBoundOffset + 1,
                    limitedBy: result.endIndex
                ) ?? result.endIndex
            } else {
                searchStart = range.upperBound
            }
        }
        return result
    }

    private static func isPathComponentContinuationCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "." || character == "_"
            || character == "-"
    }

    /// Keep the start and end of stdout so command context and final lines are
    /// both visible.
    static func capLeadingAndTrailing(_ value: String) -> String {
        cap(value, mode: .leadingAndTrailing)
    }

    /// Keep the tail of stderr because CLIs usually print the useful error last.
    static func capTrailing(_ value: String) -> String {
        cap(value, mode: .trailing)
    }

    private enum CapMode {
        case leadingAndTrailing
        case trailing
    }

    private static func cap(_ value: String, mode: CapMode) -> String {
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var truncated = false
        var selected = lines
        if lines.count > maxLines {
            truncated = true
            switch mode {
            case .leadingAndTrailing:
                let headCount = maxLines / 2
                let tailCount = maxLines - headCount
                selected = Array(lines.prefix(headCount)) + ["[truncated]"] + Array(lines.suffix(tailCount))
            case .trailing:
                selected = ["[truncated]"] + Array(lines.suffix(maxLines))
            }
        }

        var result = selected.joined(separator: "\n")
        guard result.count > maxCharacters else {
            return truncated && !result.contains("[truncated]") ? result + "\n[truncated]" : result
        }

        truncated = true
        let marker = "\n[truncated]"
        let markerBudget = marker.count
        let budget = max(0, maxCharacters - markerBudget)
        switch mode {
        case .leadingAndTrailing:
            let headCount = budget / 2
            let tailCount = budget - headCount
            result = String(result.prefix(headCount)) + marker + String(result.suffix(tailCount))
        case .trailing:
            result = "[truncated]\n" + String(result.suffix(budget))
        }
        return result
    }
}
