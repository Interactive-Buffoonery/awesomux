import AwesoMuxCore
import Foundation

struct TerminalPathBarModel: Equatable, Sendable {
    var project: String
    var path: String
    var activePaneTitle: String
    var branch: String?
    var revealURL: URL?
    var copyPath: String
    /// Filesystem path of the enclosing git repo root, or nil when the cwd isn't
    /// inside a repo. Drives the display path (set for any `.git` marker).
    var repoRootPath: String?
    /// Repo root whose `.git` admin dir passed validation — the only root we run
    /// git/gh subprocesses against, so an attacker-shaped `.git` never gets git
    /// invoked on it. Non-nil even for a detached-but-valid repo (where
    /// `gitBranch` is nil but dirty status is still meaningful).
    var validatedRepoRootPath: String?
    /// The raw local branch name (`refs/heads/<name>`), or nil for a detached
    /// HEAD / non-branch ref. Drives the `gh` PR lookup + its cache key; distinct
    /// from the display `branch`, which may be shortened or a short SHA.
    var gitBranch: String?
    /// The open PR for `gitBranch`, filled in by a second async pass after the
    /// fast local resolution (see `TerminalPathBarView`). Nil until resolved.
    var pullRequest: PullRequestInfo?
    /// Working-copy dirty/ahead/behind state, filled in by an async pass after the
    /// fast local resolution. Nil until resolved (or when not a git repo).
    var gitStatus: GitStatusInfo?
    /// CI state for the branch's newest GitHub Actions run, filled in by an async
    /// pass after the fast local resolution. Nil until resolved (or when passing /
    /// no runs / not a GitHub repo).
    var ciStatus: CIStatusInfo?
    /// The remote host when the active pane is in an SSH/remote session, else nil.
    /// Mirrors `TerminalPane.remoteHost` (detected from the title, cleared by a
    /// local OSC 7 pwd event). When non-nil the bar shows a remote indicator and
    /// suppresses every local-only affordance — the cwd/git state is the stale
    /// LOCAL machine's and must not be acted on.
    var remoteHost: String?
    /// Runtime-only remote connection health for the active pane.
    var remoteConnectionHealth: RemoteConnectionHealth

    var accessibilityLabel: String {
        // Speak the full home-abbreviated, deep-collapsed, length-capped path
        // (front-truncated so the leaf survives) rather than the visual
        // `path`, which is only the repo-relative tail. `copyPath` is the
        // absolute real path, the right input for the formatter.
        "Path Bar, \(project), \(TerminalAccessibilityPathFormatter.format(copyPath))"
    }

    /// Empty model shown before the first async resolution completes.
    static let placeholder = TerminalPathBarModel(
        project: "",
        path: "",
        activePaneTitle: "",
        branch: nil,
        revealURL: nil,
        copyPath: "",
        repoRootPath: nil,
        validatedRepoRootPath: nil,
        gitBranch: nil,
        pullRequest: nil,
        gitStatus: nil,
        ciStatus: nil,
        remoteHost: nil,
        remoteConnectionHealth: .active
    )

    /// Cheap, no-I/O first paint. Derives project/path from string operations
    /// only — no filesystem walk, no git reads — so it is safe to call on the
    /// main thread while the authoritative `make(session:)` resolves off-thread.
    static func preview(
        session: TerminalSession,
        homeDirectory: URL = TerminalPathBarModel.defaultHomeDirectory
    ) -> TerminalPathBarModel {
        let pane = session.activePane ?? TerminalPane(
            title: session.title,
            workingDirectory: session.workingDirectory
        )
        let info = PathInfo(previewing: pane.workingDirectory, homeDirectory: homeDirectory)
        return TerminalPathBarModel(
            project: info.project,
            path: info.displayPath,
            activePaneTitle: TerminalAccessibilityPathFormatter.sanitizedForSpeech(pane.title),
            branch: nil,
            revealURL: nil,
            copyPath: info.copyPath,
            repoRootPath: nil,
            validatedRepoRootPath: nil,
            gitBranch: nil,
            pullRequest: nil,
            gitStatus: nil,
            ciStatus: nil,
            remoteHost: pane.remoteHost,
            remoteConnectionHealth: pane.remoteConnectionHealth
        )
    }

    /// Authoritative resolution. Walks the filesystem and reads git state, so it
    /// MUST run off the main thread (see `TerminalPathBarView`'s `.task`).
    static func make(
        session: TerminalSession,
        fileManager: FileManager = .default,
        homeDirectory: URL = TerminalPathBarModel.defaultHomeDirectory
    ) -> TerminalPathBarModel {
        let pane = session.activePane ?? TerminalPane(
            title: session.title,
            workingDirectory: session.workingDirectory
        )
        let pathInfo = PathInfo(
            workingDirectory: pane.workingDirectory,
            fallbackProject: session.title,
            fileManager: fileManager,
            homeDirectory: homeDirectory
        )

        return TerminalPathBarModel(
            project: pathInfo.project,
            path: pathInfo.displayPath,
            activePaneTitle: TerminalAccessibilityPathFormatter.sanitizedForSpeech(pane.title),
            branch: pathInfo.branch,
            revealURL: pathInfo.revealURL,
            copyPath: pathInfo.copyPath,
            repoRootPath: pathInfo.repoRootPath,
            validatedRepoRootPath: pathInfo.validatedRepoRootPath,
            gitBranch: pathInfo.gitBranch,
            pullRequest: nil,
            gitStatus: nil,
            ciStatus: nil,
            remoteHost: pane.remoteHost,
            remoteConnectionHealth: pane.remoteConnectionHealth
        )
    }

    // Resolved once per process — the home directory can't change mid-run, so
    // rebuilding the URL on every call was pure waste (mirrors the cache in
    // TerminalAccessibilityPathFormatter). Canonical so the no-I/O preview's
    // `collapseHome` matches ingest-canonicalized working directories under a
    // symlinked home (INT-498) — the async `make` path re-resolves and is
    // unaffected either way.
    static let defaultHomeDirectory = URL(
        fileURLWithPath: WorkingDirectoryValidator.canonicalHomeDirectory,
        isDirectory: true
    )
}

private struct PathInfo {
    let project: String
    let displayPath: String
    let branch: String?
    let revealURL: URL?
    let copyPath: String
    let repoRootPath: String?
    let validatedRepoRootPath: String?
    let gitBranch: String?

    /// No-I/O preview: pure string derivation of project + display path.
    init(previewing rawWorkingDirectory: String, homeDirectory: URL) {
        // Trim only newlines (OSC 7 transport artifacts) — never spaces, which
        // can be legitimate trailing bytes in a directory name.
        let raw = rawWorkingDirectory.trimmingCharacters(in: .newlines)
        let expanded = Self.expandHome(raw.isEmpty ? "~" : raw, homeDirectory: homeDirectory)
        // Pure path normalization only — `standardizedFileURL` resolves
        // `.`/`..`/trailing slashes without touching disk; symlink resolution
        // (which stats) is deliberately left to the async `make` path.
        let directoryURL = URL(fileURLWithPath: expanded).standardizedFileURL

        if directoryURL.path == "/" {
            project = "/"
            displayPath = ""
        } else {
            let collapsed = Self.collapseHome(directoryURL.path, homeDirectory: homeDirectory)
            project = Self.displayString(directoryURL.lastPathComponent).nilIfEmpty ?? "workspace"
            displayPath = Self.displayString(collapsed)
        }
        branch = nil
        revealURL = nil
        copyPath = directoryURL.path
        repoRootPath = nil
        validatedRepoRootPath = nil
        gitBranch = nil
    }

    init(
        workingDirectory rawWorkingDirectory: String,
        fallbackProject: String,
        fileManager: FileManager,
        homeDirectory: URL
    ) {
        // Layering: the *raw* working directory drives every filesystem
        // operation, copy, and reveal. Sanitization for display happens only on
        // the strings that get shown/spoken — sanitizing before `fileExists`
        // would corrupt valid paths (a real `bad\tpath` dir would be statted as
        // `bad path`) and make Copy Path hand back something that won't `cd`.
        // Trim only newlines (OSC 7 transport artifacts) — never spaces, which
        // can be legitimate trailing bytes in a directory name (the path would
        // otherwise be statted, copied, and revealed with the name truncated).
        let raw = rawWorkingDirectory.trimmingCharacters(in: .newlines)
        // Resolve the home symlink once so home expansion/collapse and the
        // repo-relative prefix comparison all operate in the same canonical
        // form as the symlink-resolved `directoryURL` below. Without this, a
        // home (or cwd) reached through a symlink — `/tmp`→`/private/tmp`, a
        // user's `~/dev`→`~/Developer` — breaks `~` collapsing and repo-root
        // detection because the two sides standardize differently.
        let home = homeDirectory.resolvingSymlinksInPath().standardizedFileURL
        let expandedPath = Self.expandHome(
            raw.isEmpty ? "~" : raw,
            homeDirectory: home
        )
        let directoryURL = URL(fileURLWithPath: expandedPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        // The first ancestor that actually exists. When the cwd was deleted out
        // from under a shell, this backs off to a live directory so the label,
        // tooltip, Copy Path, and Reveal all agree on one real folder (INT-507
        // review: previously they could point at three different places).
        let effectiveURL = Self.existingDirectoryURL(
            startingAt: directoryURL,
            fileManager: fileManager
        ) ?? directoryURL
        let repoRootURL = Self.repoRootURL(startingAt: effectiveURL, fileManager: fileManager)

        let rawProject: String
        let rawDisplayPath: String
        if let repoRootURL {
            let relativePath = Self.relativePath(from: repoRootURL, to: effectiveURL)
            rawProject = repoRootURL.lastPathComponent
            rawDisplayPath = relativePath.isEmpty ? "repo root" : relativePath
            repoRootPath = repoRootURL.path
            // Only a `.git` that passes the admin-dir validation is trusted enough
            // to run git subprocesses against. `repoRootPath` is set for any `.git`
            // marker (it drives the display path), but `validatedRepoRootPath` —
            // which scopes the gh/git lookups — is set only when the gitdir resolved,
            // so we never invoke git on an attacker-shaped `.git`. It stays non-nil
            // for a detached-but-valid repo (where `gitBranch` is nil).
            let gitDirectoryURL = Self.resolvedGitDirectoryURL(
                repoRootURL: repoRootURL,
                fileManager: fileManager
            )
            validatedRepoRootPath = gitDirectoryURL == nil ? nil : repoRootURL.path
            let head = gitDirectoryURL
                .map { Self.headInfo(gitDirectoryURL: $0, fileManager: fileManager) }
            branch = head?.display
            gitBranch = head?.lookup
        } else if effectiveURL.path == "/" {
            rawProject = "/"
            rawDisplayPath = ""
            branch = nil
            repoRootPath = nil
            validatedRepoRootPath = nil
            gitBranch = nil
        } else {
            rawProject = effectiveURL.lastPathComponent
            rawDisplayPath = Self.collapseHome(effectiveURL.path, homeDirectory: home)
            branch = nil
            repoRootPath = nil
            validatedRepoRootPath = nil
            gitBranch = nil
        }

        project = Self.displayString(rawProject).nilIfEmpty
            ?? Self.displayString(fallbackProject).nilIfEmpty
            ?? "workspace"
        displayPath = Self.displayString(rawDisplayPath)
        revealURL = effectiveURL
        copyPath = effectiveURL.path
    }

    // MARK: - Display sanitization

    /// Strips C0/DEL control bytes (to spaces) for anything rendered or spoken.
    /// Applied only to display strings — never to a path used for I/O.
    private static func displayString(_ value: String) -> String {
        TerminalAccessibilityPathFormatter.sanitizedForSpeech(value)
    }

    // MARK: - Home expansion / collapse

    private static func expandHome(_ path: String, homeDirectory: URL) -> String {
        guard path == "~" || path.hasPrefix("~/") else {
            return path
        }

        let suffix = path.dropFirst()
        return homeDirectory.path + suffix
    }

    private static func collapseHome(_ path: String, homeDirectory: URL) -> String {
        let homePath = homeDirectory.standardizedFileURL.path
        guard path == homePath || path.hasPrefix(homePath + "/") else {
            return path
        }

        let suffix = String(path.dropFirst(homePath.count))
        return suffix.isEmpty ? "~" : "~" + suffix
    }

    // MARK: - Filesystem walks

    private static func existingDirectoryURL(
        startingAt url: URL,
        fileManager: FileManager
    ) -> URL? {
        var candidate = url.standardizedFileURL

        while true {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? candidate : candidate.deletingLastPathComponent()
            }

            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else {
                return nil
            }
            candidate = parent
        }
    }

    private static func repoRootURL(
        startingAt url: URL,
        fileManager: FileManager
    ) -> URL? {
        var candidate = url.standardizedFileURL

        while true {
            let gitPath = candidate.appendingPathComponent(".git").path
            if fileManager.fileExists(atPath: gitPath) {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else {
                return nil
            }
            candidate = parent
        }
    }

    // MARK: - Git directory resolution (validated)

    /// Resolves the git admin directory for a repo root, validating it before we
    /// ever read from it. `.git` may be a directory (normal repo) or a file
    /// containing `gitdir: <path>` (worktree / submodule). A hostile repo can
    /// point that `gitdir:` at any absolute or relative path, so the resolved
    /// target must look like a real git admin directory, and for worktrees its
    /// backlink must point back to the `.git` file we started from. Anything
    /// that fails validation yields `nil` (no branch chip) rather than a read
    /// from an attacker-chosen location.
    private static func resolvedGitDirectoryURL(
        repoRootURL: URL,
        fileManager: FileManager
    ) -> URL? {
        let dotGitURL = repoRootURL.appendingPathComponent(".git")
        // A legitimate `.git` is a regular directory or a regular file, never a
        // symlink. Reject a symlinked `.git` outright — following it would let an
        // attacker-planted link redirect the whole validated-gitdir contract at an
        // arbitrary target (and then `git` itself would operate there).
        guard let isSymlink = try? dotGitURL.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        ).isSymbolicLink, !isSymlink else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dotGitURL.path, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue {
            return isGitAdminDirectory(dotGitURL, fileManager: fileManager) ? dotGitURL : nil
        }

        guard let line = readBoundedFirstLine(dotGitURL, fileManager: fileManager) else {
            return nil
        }

        let marker = "gitdir:"
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(marker) else {
            return nil
        }

        let gitDirectoryPath = trimmed
            .dropFirst(marker.count)
            .trimmingCharacters(in: .whitespaces)
        guard !gitDirectoryPath.isEmpty else {
            return nil
        }

        let candidate: URL = gitDirectoryPath.hasPrefix("/")
            ? URL(fileURLWithPath: gitDirectoryPath)
            : repoRootURL.appendingPathComponent(gitDirectoryPath)
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL

        var targetIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &targetIsDirectory),
              targetIsDirectory.boolValue,
              isGitAdminDirectory(resolved, fileManager: fileManager) else {
            return nil
        }

        // Worktree admin dirs carry a `commondir` and a `gitdir` backlink. When
        // present, require the backlink to resolve to the `.git` file we read —
        // this is the containment check that a redirected gitdir can't forge.
        let commondirURL = resolved.appendingPathComponent("commondir")
        if fileManager.fileExists(atPath: commondirURL.path) {
            guard worktreeBacklinkMatches(
                adminDirectory: resolved,
                dotGitFileURL: dotGitURL,
                fileManager: fileManager
            ) else {
                return nil
            }
        }

        return resolved
    }

    /// A git admin directory has a regular-file `HEAD` plus either a `commondir`
    /// (worktree admin dir) or both `objects/` and `refs/` (full repo /
    /// submodule). A bare directory an attacker redirected us at — `~/.ssh`,
    /// say — has none of these, so it fails here and we never read its files.
    private static func isGitAdminDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        let headURL = url.appendingPathComponent("HEAD")
        var headIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: headURL.path, isDirectory: &headIsDirectory),
              !headIsDirectory.boolValue else {
            return false
        }

        if fileManager.fileExists(atPath: url.appendingPathComponent("commondir").path) {
            return true
        }

        var objectsIsDirectory: ObjCBool = false
        var refsIsDirectory: ObjCBool = false
        let hasObjects = fileManager.fileExists(
            atPath: url.appendingPathComponent("objects").path,
            isDirectory: &objectsIsDirectory
        ) && objectsIsDirectory.boolValue
        let hasRefs = fileManager.fileExists(
            atPath: url.appendingPathComponent("refs").path,
            isDirectory: &refsIsDirectory
        ) && refsIsDirectory.boolValue
        return hasObjects && hasRefs
    }

    private static func worktreeBacklinkMatches(
        adminDirectory: URL,
        dotGitFileURL: URL,
        fileManager: FileManager
    ) -> Bool {
        let backlinkURL = adminDirectory.appendingPathComponent("gitdir")
        guard let content = readBoundedFirstLine(backlinkURL, fileManager: fileManager) else {
            return false
        }

        let backlinkPath = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !backlinkPath.isEmpty else {
            return false
        }

        let backlinkURLResolved = (backlinkPath.hasPrefix("/")
            ? URL(fileURLWithPath: backlinkPath)
            : adminDirectory.appendingPathComponent(backlinkPath))
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let expected = dotGitFileURL.resolvingSymlinksInPath().standardizedFileURL
        return backlinkURLResolved.path == expected.path
    }

    // MARK: - Branch parsing

    /// Reads `.git/HEAD` once and derives both the chip's display string and the
    /// raw local branch name used for the PR lookup. `lookup` is non-nil only for
    /// a real `refs/heads/<name>` branch — a remote ref, detached HEAD, or
    /// unreadable HEAD has no branch to ask `gh pr view` about, so the PR chip is
    /// skipped while the branch chip may still show a shortened label / short SHA.
    private static func headInfo(
        gitDirectoryURL: URL,
        fileManager: FileManager
    ) -> (display: String?, lookup: String?) {
        let headURL = gitDirectoryURL.appendingPathComponent("HEAD")
        guard let line = readBoundedFirstLine(headURL, fileManager: fileManager) else {
            return (nil, nil)
        }

        let head = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let refPrefix = "ref:"
        if head.hasPrefix(refPrefix) {
            let ref = head
                .dropFirst(refPrefix.count)
                .trimmingCharacters(in: .whitespaces)
            let branchPrefix = "refs/heads/"
            if ref.hasPrefix(branchPrefix) {
                let name = String(ref.dropFirst(branchPrefix.count))
                return (sanitizedBranch(name), name.isEmpty ? nil : name)
            }

            // Non-branch symbolic ref (e.g. refs/remotes/origin/main): show the
            // last meaningful component(s) rather than leaking the raw ref path
            // behind a branch icon. No local branch → no PR lookup.
            let components = ref.split(separator: "/").map(String.init)
            if ref.hasPrefix("refs/remotes/"), components.count >= 2 {
                return (sanitizedBranch(components.suffix(2).joined(separator: "/")), nil)
            }
            if let last = components.last {
                return (sanitizedBranch(last), nil)
            }
            return (sanitizedBranch(ref), nil)
        }

        // Detached HEAD is a raw object id. Only render it as a short SHA when it
        // actually is ASCII hex — a non-hex / truncated HEAD (mid-rebase,
        // tooling) gets no chip rather than `@ <garbage>`. The ASCII guard
        // matters: `isHexDigit` alone also admits fullwidth Unicode hex glyphs
        // (U+FF10…), which a hostile HEAD could use to render an odd chip.
        guard head.count >= 7, head.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            return (nil, nil)
        }
        return ("@ " + String(head.prefix(7)), nil)
    }

    /// Strips control bytes and bidi override/embedding/isolate format
    /// characters from a branch label, then caps its length. The branch comes
    /// from another repo's `.git/HEAD` (a clone, a dependency, an agent's
    /// checkout) and is rendered into the chip, tooltip, VoiceOver, and the
    /// clipboard — a U+202E override could otherwise visually spoof the chip.
    /// Bidi *marks* (LRM/RLM) are kept, matching the path-sanitizer house
    /// decision; only the spoofing-capable overrides are removed.
    private static func sanitizedBranch(_ raw: String) -> String? {
        let speechSafe = TerminalAccessibilityPathFormatter.sanitizedForSpeech(raw)
        let filtered = speechSafe.unicodeScalars.filter { !BranchNameSanitizer.isBidiOverrideScalar($0) }
        let result = String(String.UnicodeScalarView(filtered))
            .trimmingCharacters(in: .whitespaces)
        guard !result.isEmpty else {
            return nil
        }
        return String(result.prefix(120))
    }

    // MARK: - Bounded file reads

    /// Reads at most `maxBytes` of the first line of a regular file. Git's
    /// `HEAD`, `.git` pointer, and `gitdir` backlink are all tiny single-line
    /// files; a hostile repo could otherwise point us at a multi-gigabyte file
    /// or a FIFO and hang/OOM the resolver. Symlinks and non-regular files are
    /// rejected outright.
    private static func readBoundedFirstLine(
        _ url: URL,
        fileManager: FileManager,
        maxBytes: Int = 4096
    ) -> String? {
        // `attributesOfItem` follows symlinks (it reports the *target's* type), so
        // check the link itself first — otherwise a `HEAD` symlink pointing at an
        // arbitrary regular file would pass the type guard below.
        guard let isSymbolicLink = try? url.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        ).isSymbolicLink, !isSymbolicLink else {
            return nil
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular else {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes),
              let contents = String(data: data, encoding: .utf8) else {
            return nil
        }
        // Take everything up to the first line break. `prefix(while:)` (unlike
        // `split`, which omits empty subsequences) preserves a leading blank line
        // as an empty first line, so a HEAD that starts with `\n` reads as "" and
        // fails ref/SHA parsing rather than silently using the second line.
        return String(contents.prefix { $0 != "\n" && $0 != "\r" })
    }

    // MARK: - Relative path

    private static func relativePath(from root: URL, to directory: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path

        guard directoryPath != rootPath,
              directoryPath.hasPrefix(rootPath + "/") else {
            return ""
        }

        return String(directoryPath.dropFirst(rootPath.count + 1))
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

/// Shared Trojan-Source scalar detection between the chip's display
/// sanitizer (`TerminalPathBarModel.sanitizedBranch`, which STRIPS these
/// scalars and still shows a chip) and the branch-list menu
/// (`BranchListMenuModel.otherBranches`, which EXCLUDES the whole row
/// instead — a raw `for-each-ref` name is executed via `git checkout`, so
/// display-sanitizing it while acting on the unsanitized bytes would be
/// worse than not listing it).
enum BranchNameSanitizer {
    /// True for bidi override/embedding/isolate format characters (LRE/RLE/
    /// PDF/LRO/RLO, LRI/RLI/FSI/PDI) — the scalars Trojan-Source spoofing
    /// relies on. Bidi *marks* (LRM/RLM) are intentionally excluded.
    static func isBidiOverrideScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x202A...0x202E, // LRE RLE PDF LRO RLO
             0x2066...0x2069: // LRI RLI FSI PDI
            true
        default:
            false
        }
    }

    /// True if `name` carries a C0 control byte/DEL or a bidi override scalar.
    static func containsSpoofableScalars(_ name: String) -> Bool {
        name.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F || isBidiOverrideScalar(scalar)
        }
    }
}
