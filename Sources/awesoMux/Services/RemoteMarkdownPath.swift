import Foundation

/// Remote paths are lexical: the Mac's home directory and filesystem never
/// participate in normalization.
enum RemoteMarkdownPath {
    static func normalize(_ path: String) -> String? {
        guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        let home = path == "~" || path.hasPrefix("~/")
        guard home || path.hasPrefix("/") else { return nil }
        let suffix = home ? String(path.dropFirst()) : path
        var components: [Substring] = []
        for component in suffix.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                if components.isEmpty {
                    guard !home else { return nil }
                } else {
                    components.removeLast()
                }
            default: components.append(component)
            }
        }
        let joined = components.joined(separator: "/")
        return home ? (joined.isEmpty ? "~" : "~/" + joined) : "/" + joined
    }

    static func resolve(_ path: String, relativeTo directory: String?) -> String? {
        if path.hasPrefix("/") || path.hasPrefix("~") { return normalize(path) }
        guard !path.isEmpty, let directory = directory.flatMap(normalize) else { return nil }
        return normalize(directory + "/" + path)
    }

    static func joinDocumentPath(_ path: String, toDirectory directory: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"),
            let base = normalize(directory), let resolved = resolve(path, relativeTo: base),
            contains(resolved, in: base)
        else { return nil }
        return resolved
    }

    static func contains(_ path: String, in directory: String) -> Bool {
        let prefix = directory == "/" ? "/" : directory + "/"
        return path != directory && path.hasPrefix(prefix)
    }
}
