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
            // hasPrefix("/") only proves path *syntax*; it says nothing about
            // whether the target exists or is safe to read. `shouldOpenAsDocument`
            // still owns the actual safety gate (extension + codepoints).
            return documentURL(forFileURL: fileURL(for: payload))
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
        guard let baseDirectoryURL,
              baseDirectoryURL.isFileURL,
              let components = URLComponents(string: destination),
              components.scheme == nil,
              components.host == nil,
              components.query == nil else {
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
              DocumentURLValidator.allowedExtensions.contains((payload.path as NSString).pathExtension.lowercased()),
              !containsUnsafePathScalars(payload.path) else {
            return nil
        }

        let basePath = (baseDirectoryURL.path as NSString).standardizingPath
        var resolvedPayload = payload
        resolvedPayload.path = ((basePath as NSString).appendingPathComponent(payload.path) as NSString)
            .standardizingPath
        guard contains(childPath: resolvedPayload.path, in: basePath) else {
            return nil
        }
        let fileURL = fileURL(for: resolvedPayload)
        guard shouldOpenAsDocument(fileURL) else {
            return nil
        }
        return fileURL
    }

    private static func contains(childPath: String, in basePath: String) -> Bool {
        if basePath == "/" {
            return childPath.hasPrefix("/") && childPath != "/"
        }
        return childPath.hasPrefix(basePath + "/")
    }

    /// Pure pre-gate for the OPEN_URL handler: is this payload a schemeless
    /// relative markdown path worth an async cwd lookup? Mirrors the checks
    /// `documentURL(forSchemelessPath:relativeTo:)` applies to the path string
    /// itself — everything except the base join and the existence check, which
    /// need the cwd. Keeping this pure lets the handler skip the MainActor hop
    /// and amx round-trip for every payload the resolver would reject anyway.
    static func isRelativeDocumentCandidate(_ value: String) -> Bool {
        // `let parsed`, not `URL(string:)?.scheme == nil`: a nil parse would
        // make the optional-chained form pass, but `OpenURLAction.resolve`'s
        // canary guard rejects unparseable payloads, and this gate must agree.
        let value = strippingTrailingSentencePunctuation(value)
        let payload = documentPathPayload(from: value)
        guard !value.isEmpty,
              let parsed = URL(string: value), parsed.scheme == nil,
              !value.hasPrefix("/"),
              !value.hasPrefix("~"),
              DocumentURLValidator.allowedExtensions.contains((payload.path as NSString).pathExtension.lowercased()),
              !containsUnsafePathScalars(payload.path) else {
            return false
        }
        return true
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

    private struct DocumentPathPayload {
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
