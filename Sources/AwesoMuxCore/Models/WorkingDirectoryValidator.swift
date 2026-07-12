import Darwin
import Foundation

public enum WorkingDirectoryValidator {
    /// Canonical form for stored/display paths: symlinks resolved + standardized.
    /// Form-only — never adds existence or ownership semantics. Canonicalizing once
    /// at ingest is what keeps the raw home-prefix strips in the display layer
    /// correct under a symlinked/non-canonical home (INT-498) without pushing
    /// filesystem hits (and macOS firmlink asymmetry) into pure model code.
    public static func canonicalizedPath(_ path: String) -> String {
        // Absolute paths only: `URL(fileURLWithPath:)` resolves relative (and
        // empty) input against the process cwd, which would silently turn a
        // stray "" into a real directory. Pass those through untouched.
        guard path.hasPrefix("/") else {
            return path
        }

        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
    }

    /// Canonical home, resolved once per process — home is constant for the
    /// process lifetime. Every home-prefix comparison against a stored working
    /// directory must use this (not raw `homeDirectoryForCurrentUser.path`) so
    /// both sides of the compare share the same canonical form.
    public static let canonicalHomeDirectory =
        canonicalizedPath(FileManager.default.homeDirectoryForCurrentUser.path)

    /// Validates a directory reported by a terminal/daemon (live cwd, OSC 7).
    ///
    /// `requireUserOwnership` gates the owner check: it's a *startup-directory*
    /// guard (don't spawn a shell into a dir the user doesn't own), NOT a check
    /// for a reported live cwd — a user can legitimately `cd` into any directory
    /// they have search permission on (`/usr/share`, `/opt`, …). Requiring
    /// ownership for a reported cwd froze the path bar at the persisted value for
    /// every non-user-owned directory (INT-576), so reported-cwd callers leave it
    /// at the default `false`; only `validatedStartupDirectory` opts in.
    ///
    /// The `false` default is display/reveal-only. Any code that SPAWNS a process
    /// from a path must obtain it via `validatedStartupDirectory` (which passes
    /// `true`) — never from a path validated with this default.
    public static func validatedReportedDirectory(
        _ rawValue: String,
        requireUserOwnership: Bool = false,
        fileManager: FileManager = .default
    ) -> String? {
        guard let path = localPath(from: rawValue),
              path.hasPrefix("/") else {
            return nil
        }

        return validatedDirectory(
            path,
            requireUserOwnership: requireUserOwnership,
            fileManager: fileManager
        )
    }

    public static func firstValidatedReportedDirectory(
        from rawValues: [String?],
        fileManager: FileManager = .default
    ) -> String? {
        for rawValue in rawValues.compactMap({ $0 }) {
            let path = homeExpandedPath(rawValue, fileManager: fileManager)
            if let validated = validatedReportedDirectory(path, fileManager: fileManager) {
                return validated
            }
        }

        return nil
    }

    public static func validatedStartupDirectory(
        _ rawValue: String,
        fileManager: FileManager = .default
    ) -> String? {
        guard !containsControlCharacter(rawValue) else {
            return nil
        }

        let path = homeExpandedPath(rawValue, fileManager: fileManager)

        // A shell is about to spawn here: require the user own the directory so
        // we never launch into a root-owned / world-writable location (e.g. /tmp).
        return validatedReportedDirectory(
            path,
            requireUserOwnership: true,
            fileManager: fileManager
        )
    }

    public static func sanitizedRestoredDirectory(
        _ rawValue: String,
        fileManager: FileManager = .default
    ) -> String {
        guard !containsControlCharacter(rawValue) else {
            return "~"
        }

        let home = fileManager.homeDirectoryForCurrentUser.path
        let expandedPath: String
        if isHomeRelativePath(rawValue) {
            expandedPath = homeExpandedPath(rawValue, fileManager: fileManager)
        } else if rawValue.hasPrefix("/") {
            expandedPath = rawValue
        } else {
            return "~"
        }

        let standardizedPath = canonicalizedPath(expandedPath)
        let standardizedHome = canonicalizedPath(home)
        guard standardizedPath == standardizedHome
                || standardizedPath.hasPrefix(standardizedHome + "/") else {
            return "~"
        }

        guard standardizedPath != standardizedHome else {
            return rawValue == "~" || rawValue.hasPrefix("~/") ? "~" : standardizedPath
        }

        let suffix = String(standardizedPath.dropFirst(standardizedHome.count))
        if rawValue == "~" || rawValue.hasPrefix("~/") {
            return "~" + suffix
        }

        return standardizedPath
    }

    private static func homeExpandedPath(_ rawValue: String, fileManager: FileManager) -> String {
        guard isHomeRelativePath(rawValue) else {
            return rawValue
        }

        let home = fileManager.homeDirectoryForCurrentUser.path
        if rawValue == "~" {
            return home
        }
        return home + String(rawValue.dropFirst())
    }

    private static func isHomeRelativePath(_ rawValue: String) -> Bool {
        rawValue == "~" || rawValue.hasPrefix("~/")
    }

    private static func localPath(from rawValue: String) -> String? {
        guard !rawValue.isEmpty,
              !containsControlCharacter(rawValue) else {
            return nil
        }

        guard rawValue.hasPrefix("file://") else {
            return rawValue
        }

        guard let url = URL(string: rawValue),
              url.scheme?.lowercased() == "file",
              isLocalHost(url.host(percentEncoded: false)) else {
            return nil
        }

        let path = url.path(percentEncoded: false)
        guard !containsControlCharacter(path) else {
            return nil
        }

        return path
    }

    private static func validatedDirectory(
        _ path: String,
        requireUserOwnership: Bool,
        fileManager: FileManager
    ) -> String? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        // Canonicalize AFTER the existence check (which traverses symlinks) but
        // BEFORE the ownership check: `attributesOfItem` does NOT traverse a
        // final symlink, so checking the caller-named path would let a
        // user-owned symlink into a root-owned dir (e.g. /tmp) pass the spawn
        // guard. Form-only for the relaxed reported-cwd path — ownership is
        // skipped there entirely (INT-576), so its semantics are untouched.
        let canonicalPath = canonicalizedPath(path)

        // Ownership is a startup-dir guard only (see `validatedReportedDirectory`).
        // Skipping it for a reported cwd is what lets the path bar follow the shell
        // into system directories the user can `cd` into but doesn't own.
        if requireUserOwnership {
            guard let ownerAccountID = try? fileManager.attributesOfItem(atPath: canonicalPath)[.ownerAccountID] as? NSNumber,
                  ownerAccountID.uint32Value == getuid() else {
                return nil
            }
        }

        return canonicalPath
    }

    private static func isLocalHost(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else {
            return true
        }

        let lowercasedHost = host.lowercased()
        let processHostName = ProcessInfo.processInfo.hostName.lowercased()
        let localHosts: Set<String> = [
            "localhost",
            "127.0.0.1",
            "::1",
            processHostName,
            processHostName + ".local"
        ]

        return localHosts.contains(lowercasedHost)
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        var disallowed = CharacterSet.controlCharacters
        disallowed.insert(charactersIn: "\u{2028}\u{2029}")
        disallowed.insert(charactersIn: "\u{00A0}\u{1680}\u{202F}\u{205F}\u{3000}")
        disallowed.insert(charactersIn: "\u{200B}\u{200C}\u{200D}\u{200E}\u{200F}\u{2060}\u{FEFF}")
        return value.unicodeScalars.contains { disallowed.contains($0) }
    }
}
