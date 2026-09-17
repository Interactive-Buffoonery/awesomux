import AwesoMuxCore
import Foundation
import UnicodeHygiene

/// Pure decision helper: does a URL point at a local Markdown file that
/// awesoMux should open as a document pane instead of handing to the OS?
///
/// Kept free of AppKit and `@MainActor` so unit tests can drive it without
/// a running app. The runtime wiring in `GhosttyRuntime.openURL` uses this
/// as its sole gating condition — no other logic lives here.
enum MarkdownLinkIntercept {
    static func shouldOpenAsDocument(_ url: URL) -> Bool {
        documentURL(forFileURL: url) != nil
    }

    static func documentURL(forFileURL url: URL) -> URL? {
        guard url.isFileURL else {
            return nil
        }
        let payload = documentPathPayload(
            from: url.path,
            fallbackFragment: url.fragment,
            parsesInlineFragment: false
        )
        guard DocumentURLValidator.allowedExtensions.contains((payload.path as NSString).pathExtension.lowercased()),
              !containsUnsafePathScalars(payload.path) else {
            return nil
        }
        return fileURL(for: payload)
    }

    /// libghostty's default link-detection matches bare filesystem paths in
    /// addition to OSC 8-wrapped `file://` hyperlinks (INT-622), handing
    /// embedders a raw string with no scheme at all. Absolute POSIX paths and
    /// current-user `~/` paths resolve directly. Relative paths resolve
    /// against `baseDirectory` — the pane's tracked working directory —
    /// because bridge panes never emit OSC 7, so libghostty's own pwd-based
    /// resolution (`Surface.resolvePathForOpening`) can't run for them
    /// (INT-740). Mirroring upstream, a resolved relative path must exist on
    /// disk. Note the honest limit: if a stale base directory still exists
    /// and contains the same relative layout (sibling worktrees), the
    /// existence check cannot distinguish it — the click-time fresh cwd
    /// query in the OPEN_URL handler is the mitigation for that case, and
    /// this fallback is best-effort. `~user/` forms remain unhandled
    /// (INT-622).
    static func documentURL(
        forSchemelessPath path: String,
        relativeTo baseDirectory: String? = nil
    ) -> URL? {
        let path = strippingTrailingSentencePunctuation(path)
        let expanded = path.hasPrefix("~/") ? (path as NSString).expandingTildeInPath : path
        let payload = documentPathPayload(from: expanded)
        if payload.path.hasPrefix("/") {
            guard let fileURL = documentURL(forFileURL: fileURL(for: payload)) else {
                return nil
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else {
                return nil
            }
            return fileURL
        }

        // `~otheruser/` (and any still-unexpanded tilde form) is pinned as
        // rejected by INT-622's tests; joining it literally under the cwd
        // would silently widen that scope.
        guard !payload.path.hasPrefix("~"),
              let baseDirectory, baseDirectory.hasPrefix("/") else {
            return nil
        }
        // The join below is lexical: with a nonexistent base (deleted
        // worktree, dead session), `standardizingPath` still collapses `..`
        // purely textually, which can land on a real file unrelated to any
        // directory the pane ever occupied. Requiring the base to exist keeps
        // resolution anchored to a directory that was at least plausibly the
        // pane's cwd — mirroring WorkingDirectoryValidator's validate-then-
        // canonicalize ordering.
        var baseIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: baseDirectory, isDirectory: &baseIsDirectory),
              baseIsDirectory.boolValue else {
            return nil
        }
        var resolvedPayload = payload
        resolvedPayload.path = ((baseDirectory as NSString).appendingPathComponent(payload.path) as NSString).standardizingPath
        let fileURL = fileURL(for: resolvedPayload)
        var isDirectory: ObjCBool = false
        guard shouldOpenAsDocument(fileURL),
              FileManager.default.fileExists(atPath: resolvedPayload.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return fileURL
    }

    /// Resolves a Markdown document-pane link destination against the source
    /// document's directory without touching the filesystem. Document rendering runs
    /// on the main update path, so existence/readability stays with the click/open
    /// path (`DocumentLoader`) rather than blocking attributed-string construction.
    ///
    /// This is intentionally narrower than full Markdown URI handling for INT-758.
    /// Queries stay plain text until query behavior has a product contract. Parent
    /// traversal that escapes the source document directory stays plain text.
    /// Common `docs/file.md#section` and `docs/file.md:12` links still open the
    /// document; scroll-to-anchor/line behavior can layer on later without changing
    /// clickability.
    static func documentURL(
        forMarkdownDestination destination: String,
        relativeTo baseDirectoryURL: URL?
    ) -> URL? {
        guard let baseDirectoryURL, baseDirectoryURL.isFileURL else {
            return nil
        }
        guard
            let resolved = resolvedDocumentPath(
                forMarkdownDestination: destination,
                relativeToDirectory: baseDirectoryURL.path
            )
        else {
            return nil
        }
        let fileURL = fileURL(
            for: DocumentPathPayload(
                path: resolved.path,
                fragment: resolved.fragment,
                line: nil,
                column: nil
            )
        )
        guard shouldOpenAsDocument(fileURL) else {
            return nil
        }
        return fileURL
    }

    /// Lexical join of a schemeless relative Markdown destination onto a
    /// directory path. No filesystem I/O. Shared by local document panes and
    /// remote Md→Md navigation so containment and destination parsing cannot
    /// drift.
    ///
    /// Absolute `/…` bases standardize like local file URLs. Current-user
    /// `~/…` bases use a tilde-preserving walk that still rejects escape above
    /// the source directory. Other base shapes fail closed.
    static func resolvedDocumentPath(
        forMarkdownDestination destination: String,
        relativeToDirectory baseDirectory: String
    ) -> (path: String, fragment: String?)? {
        guard let relative = relativeMarkdownDestination(destination) else {
            return nil
        }
        guard let joined = joinRelativeDocumentPath(relative.path, toDirectory: baseDirectory)
        else {
            return nil
        }
        return (joined, relative.fragment)
    }

    /// Parses a Markdown link destination into a relative document path +
    /// optional fragment. Rejects schemes, hosts, queries, absolute/`~`
    /// forms, bad extensions, and unsafe scalars — the same pre-join gate
    /// local and remote Md→Md resolution share.
    static func relativeMarkdownDestination(
        _ destination: String
    ) -> (path: String, fragment: String?)? {
        guard let components = URLComponents(string: destination),
            components.scheme == nil,
            components.host == nil,
            components.query == nil
        else {
            return nil
        }
        guard let path = components.percentEncodedPath.removingPercentEncoding else {
            return nil
        }
        let payload = documentPathPayload(
            from: path,
            fallbackFragment: components.percentEncodedFragment?.removingPercentEncoding
        )
        guard !payload.path.isEmpty,
            !payload.path.hasPrefix("/"),
            !payload.path.hasPrefix("~"),
            DocumentURLValidator.allowedExtensions.contains(
                (payload.path as NSString).pathExtension.lowercased()
            ),
            !containsUnsafePathScalars(payload.path)
        else {
            return nil
        }
        return (payload.path, payload.fragment)
    }

    /// Joins a relative document path onto `baseDirectory` and requires the
    /// result to stay inside that directory (INT-758 containment).
    static func joinRelativeDocumentPath(
        _ relativePath: String,
        toDirectory baseDirectory: String
    ) -> String? {
        guard !relativePath.isEmpty,
            !relativePath.hasPrefix("/"),
            !relativePath.hasPrefix("~")
        else {
            return nil
        }
        if baseDirectory.hasPrefix("/") {
            let basePath = (baseDirectory as NSString).standardizingPath
            let resolved =
                ((basePath as NSString).appendingPathComponent(relativePath) as NSString)
                .standardizingPath
            guard contains(childPath: resolved, in: basePath) else {
                return nil
            }
            return resolved
        }
        if baseDirectory == "~" || baseDirectory.hasPrefix("~/") {
            return joinRelativeDocumentPathUnderTilde(
                relativePath,
                baseDirectory: baseDirectory
            )
        }
        return nil
    }

    static func contains(childPath: String, in basePath: String) -> Bool {
        if basePath == "/" {
            return childPath.hasPrefix("/") && childPath != "/"
        }
        if basePath == "~" {
            return childPath.hasPrefix("~/") && childPath != "~"
        }
        return childPath.hasPrefix(basePath + "/")
    }

    /// Lexically normalize an absolute `/…` or current-user `~/…` *file* path
    /// with the same absolute `standardizingPath` / tilde `..` walk used by
    /// `joinRelativeDocumentPath`. Rejects escape above `~/`. Callers must run
    /// this before containment checks so crafted `…/docs/../secret.md` strings
    /// cannot pass a raw prefix test.
    static func normalizedDocumentFilePath(_ path: String) -> String? {
        if path.hasPrefix("/") {
            let standardized = (path as NSString).standardizingPath
            guard standardized.hasPrefix("/"), standardized != "/" else {
                return nil
            }
            return standardized
        }
        if path.hasPrefix("~/") {
            return normalizedTildeFilePath(path)
        }
        return nil
    }

    /// Lexically normalize an absolute `/…` or `~/…` *directory* path for use
    /// as a containment root. Same walk family as `normalizedDocumentFilePath`.
    static func normalizedDocumentDirectoryPath(_ path: String) -> String? {
        if path == "/" {
            return "/"
        }
        if path.hasPrefix("/") {
            let standardized = (path as NSString).standardizingPath
            guard standardized.hasPrefix("/") else {
                return nil
            }
            return standardized
        }
        if path == "~" || path.hasPrefix("~/") {
            return normalizedTildeDirectory(path)
        }
        return nil
    }

    private static func joinRelativeDocumentPathUnderTilde(
        _ relativePath: String,
        baseDirectory: String
    ) -> String? {
        let normalizedBase: String
        if baseDirectory == "~" {
            normalizedBase = "~"
        } else if let base = normalizedTildeDirectory(baseDirectory) {
            normalizedBase = base
        } else {
            return nil
        }
        let joined: String
        if normalizedBase == "~" {
            joined = "~/" + relativePath
        } else {
            joined = (normalizedBase as NSString).appendingPathComponent(relativePath)
        }
        guard let resolved = normalizedTildeFilePath(joined) else {
            return nil
        }
        guard contains(childPath: resolved, in: normalizedBase) else {
            return nil
        }
        return resolved
    }

    /// Lexically normalizes a `~/…` directory path, rejecting escape above `~/`.
    private static func normalizedTildeDirectory(_ path: String) -> String? {
        guard path == "~" || path.hasPrefix("~/") else { return nil }
        if path == "~" { return "~" }
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

    /// Like `normalizedTildeDirectory`, but rejects a collapse back to `~`.
    /// The walk does not inspect whether the final segment is a directory;
    /// `~/repo/docs/../file.md` keeps the filename because `file.md` remains
    /// after `..` is applied, the same as the directory walk.
    private static func normalizedTildeFilePath(_ path: String) -> String? {
        guard path.hasPrefix("~/") else { return nil }
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
        guard !components.isEmpty else { return nil }
        return "~/" + components.joined(separator: "/")
    }

    /// Pure pre-gate for the OPEN_URL handler: is this payload a schemeless
    /// relative markdown path worth an async cwd lookup? Mirrors the checks
    /// `documentURL(forSchemelessPath:relativeTo:)` applies to the path string
    /// itself — everything except the base join and the existence check, which
    /// need the cwd. Keeping this pure lets the handler skip the MainActor hop
    /// and amx round-trip for every payload the resolver would reject anyway.
    static func isRelativeDocumentCandidate(_ value: String) -> Bool {
        relativeDocumentCandidatePath(value) != nil
    }

    /// Same gate as `isRelativeDocumentCandidate`, returning the stripped
    /// path so callers that also need it for display (the recent-link palette
    /// preview) don't re-derive it and risk drifting from this check.
    static func relativeDocumentCandidatePath(_ value: String) -> String? {
        let path = documentCandidatePath(from: value)
        // Parse the line-suffix-stripped `path`, not the raw `value`:
        // Foundation's `URL` parser treats a bare top-level `README.md:12`
        // as scheme `README.md` (colon before the first `/`), which would
        // wrongly reject a plain same-directory `file:line` reference — the
        // exact link shape compiler/agent output produces.
        guard !path.isEmpty,
            let parsed = URL(string: path), parsed.scheme == nil,
            !path.hasPrefix("/"),
            !path.hasPrefix("~"),
            DocumentURLValidator.allowedExtensions.contains((path as NSString).pathExtension.lowercased()),
            !containsUnsafePathScalars(path)
        else {
            return nil
        }
        return path
    }

    /// Removes terminal-link decoration that identifies a location within a
    /// document rather than part of its filesystem path. Remote and local
    /// routing must share this step before URL scheme detection so a bare
    /// `README.md:12` is not misclassified as scheme `README.md`.
    static func documentCandidatePath(from value: String) -> String {
        let value = strippingTrailingSentencePunctuation(value)
        return documentPathPayload(from: value).path
    }

    /// libghostty's bare-path regex (`rooted_or_relative_path_branch` /
    /// `bare_relative_path_branch` in `vendor/ghostty/src/config/url.zig`)
    /// only excludes trailing sentence punctuation for its scheme-URL branch
    /// (`no_trailing_punctuation`, `.`/`,` only) — a path mentioned at the
    /// end of a sentence ("see notes.md.") hands us the trailing punctuation
    /// as part of the match, which then fails the extension check below
    /// (the real file has no such extension). `path_chars` in that same
    /// file (`[\w\-.~:\/?#@!$&*+;=%]`) additionally includes `?` and `!`,
    /// so both English sentence-enders survive into the bare-path match too
    /// — strip all four, mirroring (and extending) the tradeoff libghostty
    /// already makes for scheme URLs. `,` never actually reaches this path
    /// under the default config (`path_chars` excludes it), but keeping it
    /// costs nothing and future-proofs against a custom `link` regex.
    ///
    /// Internal, not `private`: `RemoteMarkdownSnapshotFetcher` hits the
    /// identical raw-payload-from-libghostty problem for remote panes and
    /// shares this fence rather than re-deriving it.
    ///
    /// Scans `unicodeScalars`, not `Character` — matches this file's own
    /// `containsUnsafePathScalars`/`UnicodeHygiene` convention of scalar-level
    /// inspection for path-safety-adjacent text, so a trailing period fused
    /// into a combining-mark grapheme cluster can't silently defeat the strip.
    static func strippingTrailingSentencePunctuation(_ value: String) -> String {
        var scalars = value.unicodeScalars
        while let last = scalars.last, last == "." || last == "," || last == "?" || last == "!" {
            scalars.removeLast()
        }
        return String(scalars)
    }

    struct DocumentPathPayload {
        var path: String
        var fragment: String?
        var line: Int?
        var column: Int?
    }

    private static func documentPathPayload(
        from value: String,
        fallbackFragment: String? = nil,
        parsesInlineFragment: Bool = true
    ) -> DocumentPathPayload {
        var path = value
        var fragment = fallbackFragment
        if parsesInlineFragment, let hash = path.firstIndex(of: "#") {
            let anchor = path[path.index(after: hash)...]
            fragment = anchor.isEmpty ? fragment : String(anchor)
            path.removeSubrange(hash...)
        }

        var line: Int?
        var column: Int?
        // Numeric suffixes after a Markdown extension are treated as source
        // locations, matching compiler/agent output (`file.md:12[:5]`).
        // Literal POSIX filenames with that exact ending are therefore outside
        // the click-to-open shorthand; use file picker/Open Markdown for them.
        if let suffix = lineSuffix(in: path) {
            line = suffix.line
            column = suffix.column
            path.removeSubrange(suffix.range)
        }

        return DocumentPathPayload(path: path, fragment: fragment, line: line, column: column)
    }

    private static func lineSuffix(
        in path: String
    ) -> (range: Range<String.Index>, line: Int, column: Int?)? {
        let nameStart = path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex
        guard let lastColon = path.lastIndex(of: ":"),
              lastColon >= nameStart,
              lastColon < path.index(before: path.endIndex),
              let lastNumber = Int(path[path.index(after: lastColon)...]) else {
            return nil
        }

        let beforeLastColon = path[..<lastColon]
        guard let previousColon = beforeLastColon.lastIndex(of: ":"),
              previousColon >= nameStart,
              previousColon < beforeLastColon.index(before: beforeLastColon.endIndex),
              let line = Int(beforeLastColon[beforeLastColon.index(after: previousColon)...]) else {
            return (lastColon..<path.endIndex, lastNumber, nil)
        }
        return (previousColon..<path.endIndex, line, lastNumber)
    }

    private static func fileURL(for payload: DocumentPathPayload) -> URL {
        let fileURL = URL(fileURLWithPath: payload.path)
        guard let fragment = payload.fragment,
              !fragment.isEmpty,
              var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false) else {
            return fileURL
        }
        components.percentEncodedFragment = fragment.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
        return components.url ?? fileURL
    }

    /// Forwards to `UnicodeHygiene`, the single fence for path safety — the
    /// bridge protocol (INT-698) needs this same check from `AwesoMuxCore`
    /// and helper targets, and a security fence must never be duplicated.
    static func containsUnsafePathScalars(_ string: String) -> Bool {
        UnicodeHygiene.containsUnsafePathScalars(string)
    }
}
