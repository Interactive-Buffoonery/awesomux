import Foundation
import UnicodeHygiene

public enum RemoteWorkingDirectoryValidator {
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
        return (path as NSString).standardizingPath
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
