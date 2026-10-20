import AwesoMuxTestSupport
import Foundation
import Testing
@testable import awesoMux

@Suite struct MarkdownLinkInterceptTests {
    @Test(arguments: [
        ("file:///tmp/notes.md", true), ("file:///tmp/a.markdown", true),
        ("https://x.com/a.md", false), ("file:///tmp/a.txt", false),
        ("file:///Applications/Calculator.app", false), ("file:///tmp/evil.sh", false),
        ("file:///tmp/x.dmg", false),
    ])
    func documentSchemeAndExtension(raw: String, expected: Bool) throws {
        #expect(MarkdownLinkIntercept.shouldOpenAsDocument(try #require(URL(string: raw))) == expected)
    }

    @Test(arguments: ["", ":12:5", ".", ",", "..", "?", "!", ":12:5.", "#install", "#install.", "/"])
    func absoluteSchemelessPath(suffix: String) throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "README.md")
        let raw = suffix == "/" ? "/\(file.path)" : file.path + suffix
        let url = try #require(MarkdownLinkIntercept.documentURL(forSchemelessPath: raw))
        if suffix != "/" { #expect(url.path == file.path) }
        #expect(url.host == nil)
        #expect(url.fragment == (suffix.hasPrefix("#") ? "install" : nil))
    }

    @Test(arguments: [
        "~otheruser/notes.md", "notes.md", "./notes.md", "../notes.md", "/tmp/notes.txt",
        "/tmp/\u{202E}notes.md", "/tmp/notes\n.md",
    ])
    func schemelessPathRefusals(raw: String) {
        #expect(MarkdownLinkIntercept.documentURL(forSchemelessPath: raw) == nil)
    }

    @Test(arguments: ["", "."])
    func currentUserTildePath(suffix: String) throws {
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".awesomux-test-\(UUID().uuidString).md")
        try Data("# Notes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(MarkdownLinkIntercept.documentURL(forSchemelessPath: "~/\(file.lastPathComponent)" + suffix)?.path == file.path)
    }

    @Test(arguments: ["a%0A.md"])
    func percentLookingCharactersStayLiteral(name: String) throws {
        let directory = try TemporaryDirectory(prefix: "markdown-percent")
        defer { withExtendedLifetime(directory) {} }
        let file = directory.url.appending(path: name)
        try Data("# Notes".utf8).write(to: file)
        #expect(MarkdownLinkIntercept.documentURL(forSchemelessPath: file.path)?.lastPathComponent == name)
    }

    @Test(arguments: [
        ("docs/spec.md#install", "/tmp/source-doc", "/tmp/source-doc/docs/spec.md", "install"),
        ("docs/spec.md?raw=1", "/tmp/source-doc", nil, nil),
        ("docs/spec.md:12:5", "/tmp/source-doc", "/tmp/source-doc/docs/spec.md", nil),
        ("docs/spec:v2.md", "/tmp/source-doc", "/tmp/source-doc/docs/spec:v2.md", nil),
        ("../secret.md", "/tmp/source-doc/docs", nil, nil),
        ("docs/../spec.md", "/tmp/source-doc", "/tmp/source-doc/spec.md", nil),
    ])
    func markdownDestination(raw: String, base: String, path: String?, fragment: String?) {
        let url = MarkdownLinkIntercept.documentURL(forMarkdownDestination: raw, relativeTo: URL(fileURLWithPath: base))
        #expect(url?.path == path)
        #expect(url?.fragment == fragment)
    }

    @Test(arguments: [
        ("guide.md", "~/repo/docs", "~/repo/docs/guide.md"),
        ("guide.md", "~", "~/guide.md"),
        ("../secret.md", "~/repo/docs", nil),
        ("docs/file.md", "/repo/source", "/repo/source/docs/file.md"),
        ("../secret.md", "/repo/source", nil),
        ("../../x.md", "~/repo/docs", nil),
    ])
    func resolvedDocumentPath(raw: String, base: String, path: String?) {
        let resolved = MarkdownLinkIntercept.resolvedDocumentPath(forMarkdownDestination: raw, relativeToDirectory: base)
        #expect(resolved?.path == path)
        #expect(resolved?.fragment == nil)
        if raw == "guide.md" {
            #expect(MarkdownLinkIntercept.joinRelativeDocumentPath(raw, toDirectory: base) == path)
        }
    }

    enum Base: Sendable { case fixture, omitted, absent, nonAbsolute, missing, unsafe, other }
    struct RelativeCase: Sendable {
        let raw: String
        let base: Base
        let expected: String?
        let fragment: String?
        init(_ raw: String, _ expected: String?, _ fragment: String? = nil) {
            self.init(raw, .fixture, expected, fragment)
        }
        init(_ raw: String, _ base: Base, _ expected: String?, _ fragment: String? = nil) {
            self.raw = raw; self.base = base; self.expected = expected; self.fragment = fragment
        }
    }

    @Test(arguments: [
        RelativeCase("docs/notes.md", "docs/notes.md"),
        RelativeCase("docs/notes.md.", "docs/notes.md"),
        RelativeCase("./docs/notes.md", "docs/notes.md"),
        RelativeCase("claude+int-739/a+b.md", "claude+int-739/a+b.md"),
        RelativeCase("docs/missing.md", nil),
        RelativeCase("../../notes.md", .missing, nil),
        RelativeCase("docs/notes.md", .omitted, nil),
        RelativeCase("docs/notes.md", .absent, nil),
        RelativeCase("docs/notes.md", .nonAbsolute, nil),
        RelativeCase("script.sh", nil),
        RelativeCase("docs/e\u{202E}vil.md", nil),
        RelativeCase("~otheruser/notes.md", nil),
        RelativeCase("docs/notes.md", .unsafe, nil),
        RelativeCase("{parent}/docs/notes.md", "docs/notes.md"),
        RelativeCase("{absolute}", .other, "docs/notes.md"),
        RelativeCase("docs/notes.md:12", "docs/notes.md"),
        RelativeCase("docs/notes.md#install", "docs/notes.md", "install"),
    ])
    func relativeResolution(testCase: RelativeCase) throws {
        let directory = try TemporaryDirectory(prefix: "int740")
        defer { withExtendedLifetime(directory) {} }
        let root = directory.url
        for name in ["docs/notes.md", "claude+int-739/a+b.md", "~otheruser/notes.md", "notes.md", "script.sh"] {
            let file = root.appending(path: name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("# hi".utf8).write(to: file)
        }
        let base: String?
        switch testCase.base {
        case .fixture: base = root.path
        case .absent, .omitted: base = nil
        case .nonAbsolute: base = "not/absolute"
        case .missing: base = root.appending(path: "ghost/sub").path
        case .unsafe: base = "/tmp/e\u{202E}vil"
        case .other: base = "/private/tmp"
        }
        let raw = testCase.raw.replacingOccurrences(of: "{parent}", with: "../\(root.lastPathComponent)")
            .replacingOccurrences(of: "{absolute}", with: root.appending(path: "docs/notes.md").path)
        let url =
            testCase.base == .omitted
            ? MarkdownLinkIntercept.documentURL(forSchemelessPath: raw)
            : MarkdownLinkIntercept.documentURL(forSchemelessPath: raw, relativeTo: base)
        #expect(url?.resolvingSymlinksInPath().path == testCase.expected.map { root.appending(path: $0).resolvingSymlinksInPath().path })
        #expect(url?.fragment == testCase.fragment)
    }

    @Test(arguments: [
        "docs/notes.md", "./docs/notes.md", "../notes.md", "docs/notes.md:12", "docs/notes.md#install",
        "README.md:12", "docs/notes.md.",
    ])
    func relativeCandidate(raw: String) {
        #expect(MarkdownLinkIntercept.isRelativeDocumentCandidate(raw))
    }
}
