import Foundation
import Testing
@testable import awesoMux

@Suite struct MarkdownLinkInterceptTests {
    @Test func acceptsFileMarkdown() {
        #expect(MarkdownLinkIntercept.shouldOpenAsDocument(URL(fileURLWithPath: "/tmp/notes.md")))
        #expect(MarkdownLinkIntercept.shouldOpenAsDocument(URL(string: "file:///tmp/a.markdown")!))
    }
    @Test func rejectsNonMarkdownAndRemote() {
        #expect(!MarkdownLinkIntercept.shouldOpenAsDocument(URL(string: "https://x.com/a.md")!))
        #expect(!MarkdownLinkIntercept.shouldOpenAsDocument(URL(fileURLWithPath: "/tmp/a.txt")))
    }

    // Security boundary: non-markdown file:// URLs must not pass the document
    // check. If they did, they could reach openURL and be launched without
    // confirmation via NSWorkspace (OSC 8 arbitrary-local-exec vector).
    @Test func rejectsNonMarkdownFileURLs() {
        #expect(!MarkdownLinkIntercept.shouldOpenAsDocument(
            URL(string: "file:///Applications/Calculator.app")!
        ))
        #expect(!MarkdownLinkIntercept.shouldOpenAsDocument(
            URL(string: "file:///tmp/evil.sh")!
        ))
        #expect(!MarkdownLinkIntercept.shouldOpenAsDocument(
            URL(string: "file:///tmp/x.dmg")!
        ))
    }

    // INT-622: libghostty's default link regex matches bare filesystem paths
    // (no OSC 8, no scheme) and hands the raw string to embedders. These
    // cover the schemeless-path gate independent of the OpenURLAction wiring.
    @Test func schemelessAbsolutePathOpens() {
        let url = MarkdownLinkIntercept.documentURL(forSchemelessPath: "/tmp/notes.md")
        #expect(url?.path == "/tmp/notes.md")
    }

    @Test func schemelessCurrentUserTildePathOpens() {
        let expected = (("~/notes.md") as NSString).expandingTildeInPath
        let url = MarkdownLinkIntercept.documentURL(forSchemelessPath: "~/notes.md")
        #expect(url?.path == expected)
    }

    @Test func schemelessOtherUserTildeRejected() {
        // Deliberately not supported — only the current-user `~/` shorthand
        // is expanded, per INT-622's fix scope.
        #expect(MarkdownLinkIntercept.documentURL(forSchemelessPath: "~otheruser/notes.md") == nil)
    }

    @Test func schemelessRelativePathsRejected() {
        #expect(MarkdownLinkIntercept.documentURL(forSchemelessPath: "notes.md") == nil)
        #expect(MarkdownLinkIntercept.documentURL(forSchemelessPath: "./notes.md") == nil)
        #expect(MarkdownLinkIntercept.documentURL(forSchemelessPath: "../notes.md") == nil)
    }

    @Test func schemelessNonMarkdownAbsolutePathRejected() {
        #expect(MarkdownLinkIntercept.documentURL(forSchemelessPath: "/tmp/notes.txt") == nil)
    }

    @Test func schemelessAbsolutePathWithUnsafeCodepointRejected() {
        #expect(MarkdownLinkIntercept.documentURL(forSchemelessPath: "/tmp/\u{202E}notes.md") == nil)
    }

    // C0 controls are the more common injection primitive than bidi overrides;
    // lock in embedded-newline rejection explicitly, not just RTL.
    @Test func schemelessAbsolutePathWithEmbeddedNewlineRejected() {
        #expect(MarkdownLinkIntercept.documentURL(forSchemelessPath: "/tmp/notes\n.md") == nil)
    }

    // A literal NUL scalar takes a DIFFERENT safe path than other C0 controls:
    // URL(fileURLWithPath:) percent-encodes it to inert "%00" text rather than
    // passing a real NUL through `.path`, so isUnsafePathScalar never sees it —
    // but no actual NUL byte reaches the returned URL either. Assert the real
    // safety property (no live NUL scalar survives) rather than assuming the
    // codepoint filter is what's doing the rejecting here.
    @Test func schemelessAbsolutePathWithNULByteNeverLeaksARealNUL() {
        let url = MarkdownLinkIntercept.documentURL(forSchemelessPath: "/tmp/\u{0000}notes.md")
        #expect(url?.path.unicodeScalars.contains(Unicode.Scalar(0)) != true)
    }

    // Raw strings from libghostty are never percent-decoded; a literal `%0A`
    // in a filename must stay literal, not collapse into a control character.
    @Test func schemelessPathWithPercentLookingCharactersStaysLiteral() {
        let url = MarkdownLinkIntercept.documentURL(forSchemelessPath: "/tmp/a%0A.md")
        #expect(url?.lastPathComponent == "a%0A.md")
    }

    // URL(fileURLWithPath:) treats a leading "//" as a local path, not a
    // network authority — confirm no host sneaks in via a doubled slash.
    @Test func schemelessDoubleSlashPathStaysLocal() {
        let url = MarkdownLinkIntercept.documentURL(forSchemelessPath: "//tmp/notes.md")
        #expect(url != nil)
        #expect(url?.host == nil)
    }

    @Test func schemelessAbsolutePathStripsLineSuffix() {
        let url = MarkdownLinkIntercept.documentURL(forSchemelessPath: "/tmp/notes.md:12:5")
        #expect(url?.path == "/tmp/notes.md")
    }

    // libghostty's bare-path regex only excludes trailing `.`/`,` for
    // scheme URLs (http://, mailto:, etc.), not for absolute/`~` paths
    // (vendor/ghostty/src/config/url.zig's rooted_or_relative_path_branch
    // has no no_trailing_punctuation guard) — a path mentioned at the end
    // of a sentence hands us the trailing period as part of the match.
    @Test func schemelessAbsolutePathStripsTrailingSentencePeriod() {
        let url = MarkdownLinkIntercept.documentURL(forSchemelessPath: "/tmp/notes.md.")
        #expect(url?.path == "/tmp/notes.md")
    }

    @Test func schemelessAbsolutePathStripsTrailingSentenceComma() {
        let url = MarkdownLinkIntercept.documentURL(forSchemelessPath: "/tmp/notes.md,")
        #expect(url?.path == "/tmp/notes.md")
    }

    @Test func schemelessAbsolutePathStripsMultipleTrailingPeriods() {
        let url = MarkdownLinkIntercept.documentURL(forSchemelessPath: "/tmp/notes.md..")
        #expect(url?.path == "/tmp/notes.md")
    }

    @Test func schemelessTildePathStripsTrailingSentencePeriod() {
        let expected = (("~/notes.md") as NSString).expandingTildeInPath
        let url = MarkdownLinkIntercept.documentURL(forSchemelessPath: "~/notes.md.")
        #expect(url?.path == expected)
    }

    // libghostty's path_chars ([\w\-.~:\/?#@!$&*+;=%]) includes `?` and `!`,
    // unlike `,` — an agent's closing line ending "...notes.md?" or "...md!"
    // hands us the trailing character as part of the bare-path match too.
    @Test func schemelessAbsolutePathStripsTrailingQuestionMark() {
        let url = MarkdownLinkIntercept.documentURL(forSchemelessPath: "/tmp/notes.md?")
        #expect(url?.path == "/tmp/notes.md")
    }

    @Test func schemelessAbsolutePathStripsTrailingExclamationMark() {
        let url = MarkdownLinkIntercept.documentURL(forSchemelessPath: "/tmp/notes.md!")
        #expect(url?.path == "/tmp/notes.md")
    }

    @Test func schemelessAbsolutePathStripsLineSuffixThenTrailingPeriod() {
        let url = MarkdownLinkIntercept.documentURL(forSchemelessPath: "/tmp/notes.md:12:5.")
        #expect(url?.path == "/tmp/notes.md")
    }

    @Test func schemelessAbsolutePathPreservesAnchorFragment() {
        let url = MarkdownLinkIntercept.documentURL(forSchemelessPath: "/tmp/notes.md#install")
        #expect(url?.path == "/tmp/notes.md")
        #expect(url?.fragment == "install")
    }

    @Test func schemelessAbsolutePathPreservesAnchorFragmentThenStripsTrailingPeriod() {
        let url = MarkdownLinkIntercept.documentURL(forSchemelessPath: "/tmp/notes.md#install.")
        #expect(url?.path == "/tmp/notes.md")
        #expect(url?.fragment == "install")
    }

    @Test func markdownDestinationPreservesFragmentButRejectsQuery() {
        let base = URL(fileURLWithPath: "/tmp/source-doc")
        let withFragment = MarkdownLinkIntercept.documentURL(
            forMarkdownDestination: "docs/spec.md#install",
            relativeTo: base
        )
        let withQuery = MarkdownLinkIntercept.documentURL(
            forMarkdownDestination: "docs/spec.md?raw=1",
            relativeTo: base
        )

        #expect(withFragment?.path == "/tmp/source-doc/docs/spec.md")
        #expect(withFragment?.fragment == "install")
        #expect(withQuery == nil)
    }

    // Explicit `[text](destination)` markdown syntax is parenthesis-delimited,
    // not swept up by libghostty's sentence-boundary-blind regex — a literal
    // trailing period in the destination is part of what the author wrote,
    // not an artifact to strip. Pins the asymmetry with the schemeless-path
    // functions above as intentional, not an oversight a future edit should
    // "fix" for consistency.
    @Test func markdownDestinationDoesNotStripTrailingPeriod() {
        let base = URL(fileURLWithPath: "/tmp/source-doc")
        #expect(MarkdownLinkIntercept.documentURL(
            forMarkdownDestination: "docs/spec.md.",
            relativeTo: base
        ) == nil)
    }

    @Test func markdownDestinationStripsLineSuffix() {
        let base = URL(fileURLWithPath: "/tmp/source-doc")
        let withLine = MarkdownLinkIntercept.documentURL(
            forMarkdownDestination: "docs/spec.md:12:5",
            relativeTo: base
        )

        #expect(withLine?.path == "/tmp/source-doc/docs/spec.md")
    }

    @Test func markdownDestinationKeepsNonNumericColonFilename() {
        let base = URL(fileURLWithPath: "/tmp/source-doc")
        let withColon = MarkdownLinkIntercept.documentURL(
            forMarkdownDestination: "docs/spec:v2.md",
            relativeTo: base
        )

        #expect(withColon?.path == "/tmp/source-doc/docs/spec:v2.md")
    }

    @Test func markdownDestinationCannotEscapeSourceDirectory() {
        let base = URL(fileURLWithPath: "/tmp/source-doc/docs")
        let escaped = MarkdownLinkIntercept.documentURL(
            forMarkdownDestination: "../secret.md",
            relativeTo: base
        )

        #expect(escaped == nil)
    }

    @Test func markdownDestinationAllowsContainedNormalization() {
        let base = URL(fileURLWithPath: "/tmp/source-doc")
        let resolved = MarkdownLinkIntercept.documentURL(
            forMarkdownDestination: "docs/../spec.md",
            relativeTo: base
        )

        #expect(resolved?.path == "/tmp/source-doc/spec.md")
    }
}

// INT-740: bridge panes never emit OSC 7, so libghostty can't resolve
// relative link clicks itself and hands us the raw relative string.
// These pin the embedder-side resolution against the pane's tracked cwd.
@Suite struct MarkdownLinkInterceptRelativeResolutionTests {
    /// Creates a real temp directory tree containing `docs/notes.md` and
    /// returns its root. Existence checking is part of the contract under
    /// test, so these tests touch the real filesystem.
    private func makeFixtureRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("int740-\(UUID().uuidString)", isDirectory: true)
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try Data("# hi".utf8).write(to: docs.appendingPathComponent("notes.md"))
        return root
    }

    @Test func resolvesRelativeMarkdownPathAgainstBase() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = MarkdownLinkIntercept.documentURL(
            forSchemelessPath: "docs/notes.md",
            relativeTo: root.path
        )
        // Compare with symlinks resolved on BOTH sides: the implementation's
        // NSString.standardizingPath strips /private, URL.standardizedFileURL
        // does not, and TMPDIR sits exactly on the /var↔/private/var firmlink
        // seam. Resolving both sides keeps this test about resolution, not
        // about which spelling of the temp dir macOS handed us.
        let got = url?.resolvingSymlinksInPath().path
        let want = root.appendingPathComponent("docs/notes.md").resolvingSymlinksInPath().path
        #expect(got == want)
    }

    // The absolute/tilde branch strips before the early return; this pins
    // the same behavior on the base-directory-joined branch, which does a
    // real FileManager existence check the early-return branch doesn't.
    @Test func resolvesRelativePathWithTrailingSentencePeriod() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = MarkdownLinkIntercept.documentURL(
            forSchemelessPath: "docs/notes.md.",
            relativeTo: root.path
        )
        let got = url?.resolvingSymlinksInPath().path
        let want = root.appendingPathComponent("docs/notes.md").resolvingSymlinksInPath().path
        #expect(got == want)
    }

    @Test func resolvesDotSlashPrefixedRelativePath() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = MarkdownLinkIntercept.documentURL(
            forSchemelessPath: "./docs/notes.md",
            relativeTo: root.path
        )
        #expect(url != nil)
    }

    // INT-740 repro guard: the worktree dirname contained a literal `+`
    // (`claude+int-739-group-close-badge`). `+` must survive resolution —
    // no percent-decoding may turn it into a space or reject the path.
    @Test func plusInBaseDirectoryAndFilenameSurvivesResolution() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plusDir = root.appendingPathComponent("claude+int-739", isDirectory: true)
        try FileManager.default.createDirectory(at: plusDir, withIntermediateDirectories: true)
        try Data("# hi".utf8).write(to: plusDir.appendingPathComponent("a+b.md"))
        let url = MarkdownLinkIntercept.documentURL(
            forSchemelessPath: "claude+int-739/a+b.md",
            relativeTo: root.path
        )
        #expect(url?.lastPathComponent == "a+b.md")
    }

    @Test func rejectsRelativePathWhenFileMissing() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(MarkdownLinkIntercept.documentURL(
            forSchemelessPath: "docs/missing.md",
            relativeTo: root.path
        ) == nil)
    }

    // A deleted base (merged-and-removed worktree) must not let the lexical
    // `..` collapse land on a real file the pane never had anything to do
    // with. Constructs the collision: base/ghost/sub never exists, but
    // ../../notes.md collapses to a file that does.
    @Test func rejectsRelativePathWhenBaseDirectoryMissing() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# hi".utf8).write(to: root.appendingPathComponent("notes.md"))
        let ghostBase = root.appendingPathComponent("ghost/sub", isDirectory: true).path
        #expect(MarkdownLinkIntercept.documentURL(
            forSchemelessPath: "../../notes.md",
            relativeTo: ghostBase
        ) == nil)
    }

    @Test func rejectsRelativePathWithoutBase() {
        #expect(MarkdownLinkIntercept.documentURL(forSchemelessPath: "docs/notes.md") == nil)
        #expect(MarkdownLinkIntercept.documentURL(forSchemelessPath: "docs/notes.md", relativeTo: nil) == nil)
    }

    @Test func rejectsRelativePathWithNonAbsoluteBase() {
        #expect(MarkdownLinkIntercept.documentURL(
            forSchemelessPath: "docs/notes.md",
            relativeTo: "not/absolute"
        ) == nil)
    }

    @Test func rejectsNonMarkdownRelativePath() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent("script.sh"))
        #expect(MarkdownLinkIntercept.documentURL(
            forSchemelessPath: "script.sh",
            relativeTo: root.path
        ) == nil)
    }

    @Test func rejectsRelativePathWithUnsafeCodepoint() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(MarkdownLinkIntercept.documentURL(
            forSchemelessPath: "docs/e\u{202E}vil.md",
            relativeTo: root.path
        ) == nil)
    }

    // Pinned pre-existing scope (INT-622): `~otheruser/` is rejected. Without
    // an explicit guard the relative branch would join it literally under the
    // cwd and open it if a dir named "~otheruser" existed. (Cross-model
    // review catch.)
    @Test func rejectsOtherUserTildeEvenWithBase() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let literalTildeDir = root.appendingPathComponent("~otheruser", isDirectory: true)
        try FileManager.default.createDirectory(at: literalTildeDir, withIntermediateDirectories: true)
        try Data("# hi".utf8).write(to: literalTildeDir.appendingPathComponent("notes.md"))
        #expect(MarkdownLinkIntercept.documentURL(
            forSchemelessPath: "~otheruser/notes.md",
            relativeTo: root.path
        ) == nil)
    }

    // A malformed base (control characters) must be rejected by the existing
    // unsafe-codepoint fence, which runs on the JOINED path — this pins that
    // the fence covers the base, not just the clicked string.
    @Test func rejectsBaseDirectoryWithUnsafeCodepoint() {
        #expect(MarkdownLinkIntercept.documentURL(
            forSchemelessPath: "docs/notes.md",
            relativeTo: "/tmp/e\u{202E}vil"
        ) == nil)
    }

    @Test func candidateGateAcceptsRelativeMarkdownPaths() {
        #expect(MarkdownLinkIntercept.isRelativeDocumentCandidate("docs/notes.md"))
        #expect(MarkdownLinkIntercept.isRelativeDocumentCandidate("./docs/notes.md"))
        #expect(MarkdownLinkIntercept.isRelativeDocumentCandidate("../notes.md"))
        #expect(MarkdownLinkIntercept.isRelativeDocumentCandidate("docs/notes.md:12"))
        #expect(MarkdownLinkIntercept.isRelativeDocumentCandidate("docs/notes.md#install"))
    }

    @Test func candidateGateAcceptsTopLevelFilenameWithLineSuffix() {
        // README.md:12 has a colon before the first "/" (there is no "/"),
        // so Foundation's URL parser reads scheme "README.md" unless the
        // gate strips the line suffix before parsing.
        #expect(MarkdownLinkIntercept.isRelativeDocumentCandidate("README.md:12"))
    }

    @Test func candidateGateAcceptsTrailingSentencePeriod() {
        #expect(MarkdownLinkIntercept.isRelativeDocumentCandidate("docs/notes.md."))
    }

    @Test func candidateGateRejectsNonCandidates() {
        #expect(!MarkdownLinkIntercept.isRelativeDocumentCandidate(""))
        #expect(!MarkdownLinkIntercept.isRelativeDocumentCandidate("https://example.com"))
        #expect(!MarkdownLinkIntercept.isRelativeDocumentCandidate("/tmp/notes.md"))
        #expect(!MarkdownLinkIntercept.isRelativeDocumentCandidate("~/notes.md"))
        #expect(!MarkdownLinkIntercept.isRelativeDocumentCandidate("~otheruser/notes.md"))
        #expect(!MarkdownLinkIntercept.isRelativeDocumentCandidate("docs/script.sh"))
        #expect(!MarkdownLinkIntercept.isRelativeDocumentCandidate("docs/e\u{202E}vil.md"))
    }

    // Parent traversal is allowed by design — libghostty's own resolver
    // permits it, and absolute paths to anywhere are already accepted, so
    // requiring containment would add friction without a security win.
    @Test func resolvesParentTraversalWhenTargetExists() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = MarkdownLinkIntercept.documentURL(
            forSchemelessPath: "../\(root.lastPathComponent)/docs/notes.md",
            relativeTo: root.path
        )
        #expect(url != nil)
    }

    // Absolute schemeless paths keep their existing contract: gated on
    // extension + codepoints only, no existence requirement.
    @Test func absolutePathBehaviorUnchangedByBaseParameter() {
        let url = MarkdownLinkIntercept.documentURL(
            forSchemelessPath: "/tmp/does-not-need-to-exist.md",
            relativeTo: "/private/tmp"
        )
        #expect(url?.path == "/tmp/does-not-need-to-exist.md")
    }

    @Test func resolvesRelativeLineSuffixAndAnchorAgainstBase() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lineURL = MarkdownLinkIntercept.documentURL(
            forSchemelessPath: "docs/notes.md:12",
            relativeTo: root.path
        )
        let anchorURL = MarkdownLinkIntercept.documentURL(
            forSchemelessPath: "docs/notes.md#install",
            relativeTo: root.path
        )
        #expect(lineURL?.lastPathComponent == "notes.md")
        #expect(anchorURL?.lastPathComponent == "notes.md")
        #expect(anchorURL?.fragment == "install")
    }
}
