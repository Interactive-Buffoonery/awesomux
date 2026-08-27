import Foundation
import Testing
@testable import awesoMux

// INT-622: OpenURLAction.resolve is the actual join point where the scheme
// allowlist, the file:// markdown gate, and the schemeless-path branch
// interact. Test the combined wiring directly, not just the underlying
// MarkdownLinkIntercept helper in isolation.
@Suite struct OpenURLActionResolutionTests {
    private var existingMarkdownPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "README.md")
            .path
    }

    private func makeMarkdownFile(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appending(path: name)
        try Data("# Notes".utf8).write(to: fileURL)
        return fileURL
    }

    @Test func acceptsAllowlistedSchemes() {
        #expect(OpenURLAction.resolve("https://example.com") != nil)
        #expect(OpenURLAction.resolve("http://example.com") != nil)
        #expect(OpenURLAction.resolve("mailto:someone@example.com") != nil)
        #expect(OpenURLAction.resolve("file:///tmp/notes.md") != nil)
    }

    @Test func rejectsDisallowedSchemes() {
        #expect(OpenURLAction.resolve("javascript:alert(1)") == nil)
        #expect(OpenURLAction.resolve("data:text/html,x") == nil)
        #expect(OpenURLAction.resolve("vscode://file/tmp/notes.md") == nil)
    }

    @Test func rejectsNonMarkdownFileScheme() {
        #expect(OpenURLAction.resolve("file:///tmp/script.sh") == nil)
    }

    @Test func acceptsSchemelessAbsoluteMarkdownPath() {
        let url = OpenURLAction.resolve(existingMarkdownPath)
        #expect(url?.path == existingMarkdownPath)
    }

    @Test func acceptsSchemelessAbsoluteMarkdownPathWithLineSuffixAndAnchor() {
        let url = OpenURLAction.resolve("\(existingMarkdownPath):12:5#install")
        #expect(url?.path == existingMarkdownPath)
        #expect(url?.fragment == "install")
    }

    @Test func acceptsFileMarkdownURLWithLineSuffix() {
        let url = OpenURLAction.resolve("file:///tmp/notes.md:12")
        #expect(url?.path == "/tmp/notes.md")
    }

    @Test func acceptsFileMarkdownURLWithAnchor() {
        let url = OpenURLAction.resolve("file:///tmp/notes.md#install")
        #expect(url?.path == "/tmp/notes.md")
        #expect(url?.fragment == "install")
    }

    @Test func acceptsSchemelessCurrentUserTildePath() throws {
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".awesomux-test-\(UUID().uuidString).md")
        try Data("# Notes".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        #expect(OpenURLAction.resolve("~/\(fileURL.lastPathComponent)")?.path == fileURL.path)
    }

    @Test func rejectsSchemelessRelativePath() {
        #expect(OpenURLAction.resolve("notes.md") == nil)
        #expect(OpenURLAction.resolve("../notes.md") == nil)
    }

    @Test func rejectsSchemelessNonMarkdownAbsolutePath() {
        #expect(OpenURLAction.resolve("/tmp/notes.txt") == nil)
    }

    @Test func rejectsEmptyValue() {
        #expect(OpenURLAction.resolve("") == nil)
    }

    // A raw "%" not followed by two hex digits is malformed percent-encoding.
    // Confirm it doesn't get rejected by the URL(string:) canary guard before
    // reaching the schemeless path gate (OpenCode PR review, 2026-07-02).
    @Test func acceptsSchemelessAbsolutePathWithMalformedPercentEncoding() throws {
        let fileURL = try makeMarkdownFile(named: "50%.md")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        #expect(OpenURLAction.resolve(fileURL.path)?.path == fileURL.path)
    }

    // INT-632: spaces are the case where the URL(string:) canary guard is at
    // most risk of wrongly rejecting a real path before the schemeless branch
    // (the branch re-derives from the raw string, so this pins the guard's
    // leniency, not the branch).
    @Test func acceptsSchemelessAbsoluteMarkdownPathWithSpaces() throws {
        let fileURL = try makeMarkdownFile(named: "meeting notes.md")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let url = OpenURLAction.resolve(fileURL.path)
        #expect(url?.isFileURL == true)
        #expect(url?.lastPathComponent == fileURL.lastPathComponent)
    }

    // INT-632: embedded bidi OVERRIDE (not trailing, which the extension check
    // catches coincidentally; not a hint, which may be whitelisted later per
    // the title-sanitizer precedent). Pins the unsafe-codepoint filter onto
    // the schemeless branch END TO END, so a refactor can't route around
    // MarkdownLinkIntercept silently.
    @Test func rejectsSchemelessMarkdownPathWithEmbeddedBidiOverride() {
        #expect(OpenURLAction.resolve("/tmp/e\u{202E}vil.md") == nil)
    }
}
