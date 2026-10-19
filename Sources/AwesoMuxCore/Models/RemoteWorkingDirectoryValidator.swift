import Foundation
import UnicodeHygiene

public enum RemoteWorkingDirectoryValidator {
    /// Qualifies a bounded daemon inventory report before treating its path as
    /// remote metadata; legacy startup directories cannot prove provenance.
    static func validatedDaemonReportedDirectory(
        _ rawValue: String, expectedHost: String, localHostnames: Set<String>
    ) -> String? {
        // zmx ipc.MAX_CWD_LEN silently truncates the raw URI at 256 bytes.
        guard rawValue.utf8.count < 256 else { return nil }
        return validatedNativeReport(
            rawValue, expectedHost: expectedHost, localHostnames: localHostnames)?.directory
    }

    /// Direct native reports are complete (unlike the daemon's 256-byte field).
    public static func validatedNativeReport(
        _ rawValue: String, expectedHost: String?, localHostnames: Set<String>
    ) -> (host: String, directory: String)? {
        guard rawValue.utf8.count <= 2048, rawValue.hasPrefix("file://"),
            !UnicodeHygiene.containsUnsafePathScalars(rawValue),
            !rawValue.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
            let decoded = rawValue.removingPercentEncoding,
            !UnicodeHygiene.containsUnsafePathScalars(decoded),
            let uri = URLComponents(string: rawValue), uri.scheme == "file",
            let host = uri.host, !host.isEmpty,
            rawValue.dropFirst(7).prefix(while: { $0 != "/" }) == host,
            !RemoteSessionDetector.isLoopback(host.lowercased()), host != "0.0.0.0",
            host.lowercased() != "localhost.",
            host.unicodeScalars.allSatisfy({
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
            }),
            !hostsMatch(host, "localhost"),
            !localHostnames.contains(where: { hostsMatch(host, $0) }),
            expectedHost.map({ hostsMatch(host, $0) }) ?? true,
            uri.user == nil, uri.password == nil, uri.port == nil,
            uri.query == nil, uri.fragment == nil,
            uri.percentEncodedPath.hasPrefix("/"),
            let path = uri.percentEncodedPath.removingPercentEncoding,
            path.hasPrefix("/"), !UnicodeHygiene.containsUnsafePathScalars(path),
            // Foundation may repair malformed URLs. Accept only the original encoding.
            uri.string == rawValue
        else { return nil }
        return (host, path)
    }

    public static func hostsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = lhs.lowercased()
        let rhs = rhs.lowercased()
        if lhs == rhs { return true }
        if !lhs.contains("."), rhs == lhs + ".local" { return true }
        return !rhs.contains(".") && lhs == rhs + ".local"
    }

    /// Validates a directory explicitly reported by a remote terminal, such as
    /// an OSC 7 / Ghostty PWD action. This is form-only: the path belongs to the
    /// declared remote host and must never be checked against the local file
    /// system.
    public static func validatedReportedDirectory(_ rawValue: String) -> String? {
        guard !rawValue.isEmpty,
            !UnicodeHygiene.containsUnsafePathScalars(rawValue)
        else {
            return nil
        }

        let path: String
        if rawValue.hasPrefix("file://") {
            guard let url = URL(string: rawValue),
                url.scheme?.lowercased() == "file",
                url.query == nil,
                url.fragment == nil
            else {
                return nil
            }
            path = url.path(percentEncoded: false)
        } else {
            path = rawValue
        }

        guard path.hasPrefix("/") || path == "~" || path.hasPrefix("~/"),
            !UnicodeHygiene.containsUnsafePathScalars(path)
        else {
            return nil
        }

        if path == "~" {
            return path
        }
        if path.hasPrefix("~/") {
            return normalizedTildePath(path)
        }
        return path
    }

    private static func normalizedTildePath(_ path: String) -> String? {
        var components: [Substring] = []
        for component in path.dropFirst(2).split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(component)
            }
        }
        return components.isEmpty ? "~" : "~/" + components.joined(separator: "/")
    }
}
