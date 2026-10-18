import Testing
import Foundation
import AwesoMuxTestSupport
@testable import AwesoMuxCore

@Suite("DocumentLoader")
struct DocumentLoaderTests {
    private let temporaryDirectory: TemporaryDirectory

    init() throws {
        temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-document-loader-tests")
    }

    private func writeTempFile(name: String, content: String) throws -> URL {
        let url = temporaryDirectory.url.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeTempData(name: String, size: Int) throws -> URL {
        let url = temporaryDirectory.url.appendingPathComponent(name)
        let data = Data(repeating: 0x61 /* 'a' */, count: size)
        try data.write(to: url)
        return url
    }

    @Test(arguments: [
        ("hello.md", "# Hello\n\nWorld", false), ("notes.markdown", "**bold**", false),
        ("empty.md", "", false), ("exact.md", String(repeating: "a", count: DocumentURLValidator.maxFileSizeBytes), false),
        ("target.md", "# Linked", true), ("upper.MD", "# Uppercase", false),
        ("upper.MARKDOWN", "# Uppercase", false),
    ])
    func acceptedFiles(name: String, content: String, symlink: Bool) throws {
        let target = try writeTempFile(name: name, content: content)
        let url: URL
        if symlink {
            url = temporaryDirectory.url.appending(path: "linked.md")
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        } else {
            url = target
        }
        guard case let .loaded(source, _) = DocumentLoader.load(url) else {
            Issue.record("Expected loaded source for \(name)")
            return
        }
        #expect(source.utf8.elementsEqual(content.utf8))
    }

    enum Rejection: CaseIterable { case text, oversized, https, missing, foreignOwner, fifo, symlink }

    @Test(arguments: Rejection.allCases)
    func rejectedFiles(reason: Rejection) throws {
        var url = temporaryDirectory.url.appending(path: "rejected.md")
        var uid = geteuid()
        let expected: DocumentURLValidator.Rejection
        switch reason {
        case .text:
            url = try writeTempFile(name: "notes.txt", content: "Hello")
            expected = .badExtension
        case .oversized:
            url = try writeTempData(name: "big.md", size: DocumentURLValidator.maxFileSizeBytes + 1)
            expected = .tooLarge
        case .https:
            url = try #require(URL(string: "https://example.com/doc.md"))
            expected = .notFileURL
        case .missing:
            expected = .unreadable
        case .foreignOwner:
            url = try writeTempFile(name: "untrusted.md", content: "secret")
            uid += 1
            expected = .unreadable
        case .fifo:
            try #require(mkfifo(url.path, 0o600) == 0, "Could not create FIFO fixture: \(errno)")
            expected = .unreadable
        case .symlink:
            let target = try writeTempFile(name: "real.txt", content: "plain text content")
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            expected = .badExtension
        }
        #expect(DocumentLoader.load(url, effectiveUID: uid) == .rejected(expected))
    }

    @Test("invalid UTF-8 returns a read error")
    func invalidUTF8ReturnsReadError() throws {
        let file = temporaryDirectory.url.appending(path: "invalid.md")
        try Data([0xFF]).write(to: file)
        guard case .readError = DocumentLoader.load(file) else {
            Issue.record("Expected readError for invalid UTF-8")
            return
        }
    }

    @Test("bounded source read rejects a file over the size cap")
    func boundedSourceReadRejectsOversizedFile() throws {
        let url = try writeTempData(
            name: "oversized-watched.md",
            size: DocumentURLValidator.maxFileSizeBytes + 1
        )

        #expect(DocumentLoader.readSource(url) == nil)
    }

    @Test("canonically equivalent source bytes still rebuild the render")
    func rebuildsCanonicallyEquivalentDifferentBytes() async throws {
        let prior = AttributedMarkdownBuilder.build("caf\u{00E9}")

        let output = await DocumentLoader.loadAndRender(
            load: { DocumentLoader.load(source: "cafe\u{0301}") },
            priorDocument: prior,
            render: { AttributedMarkdownBuilder.build($0) }
        )
        let document = try #require(output?.1)

        #expect(document.source.utf8.elementsEqual("cafe\u{0301}".utf8))
        #expect(!document.source.utf8.elementsEqual(prior.source.utf8))
    }
}
