import Foundation

public enum ConfigLoadError: Error, Equatable, Sendable {
    case unreadable(URL)
    case notAFile(URL)
    case invalidSyntax(line: Int, column: Int, message: String)
    case invalidValue(path: String, message: String)
    case unsupportedSchemaVersion(Int)

    public var displayText: String {
        switch self {
        case .unreadable(let url):
            return "Unable to read \(abbreviateHome(url.path))"
        case .notAFile(let url):
            return "Expected a file at \(abbreviateHome(url.path)) but found a directory or special file"
        case .invalidSyntax(let line, let column, let message):
            return "Invalid TOML at \(line):\(column): \(message)"
        case .invalidValue(let path, let message):
            return "\(displayPath(path)): \(message)"
        case .unsupportedSchemaVersion(let version):
            return "Unsupported schema version \(version)"
        }
    }
}

/// `$` is the internal path sentinel for "the root of the config" — render
/// it as `config.toml` so users (and Slack screenshots) see a name they
/// recognize rather than a jq-shaped sigil.
private func displayPath(_ path: String) -> String {
    path == "$" ? "config.toml" : path
}

/// Abbreviate `/Users/<name>/...` to `~/...` so error text in the UI and
/// logs doesn't leak the local macOS username. Mirrors the helper already
/// used by `AwesoMuxApp` for the session-recovery alert.
func abbreviateHome(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    guard path == home || path.hasPrefix(home + "/") else { return path }
    let suffix = String(path.dropFirst(home.count))
    return suffix.isEmpty ? "~" : "~" + suffix
}
