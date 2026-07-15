import Testing
import Foundation
import AwesoMuxTestSupport
@testable import AwesoMuxCore

// MARK: - DocumentLoader Tests

@Suite("DocumentLoader")
struct DocumentLoaderTests {

    // MARK: Helpers

    private func writeTempFile(name: String, content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("awesomux-document-loader-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeTempData(name: String, size: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("awesomux-document-loader-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let data = Data(repeating: 0x61 /* 'a' */, count: size)
        try data.write(to: url)
        return url
    }

    // MARK: - Happy path

    @Test("loads a valid .md file and returns blocks")
    func loadsValidMarkdown() throws {
        let url = try writeTempFile(name: "hello.md", content: "# Hello\n\nWorld")
        let result = DocumentLoader.load(url)
        guard case let .loaded(blocks, _) = result else {
            Issue.record("Expected .loaded, got \(result)")
            return
        }
        #expect(blocks.count == 2)
        #expect(blocks[0] == .heading(level: 1, [.text("Hello")]))
        guard case .paragraph = blocks[1] else {
            Issue.record("Expected paragraph at index 1, got \(blocks[1])")
            return
        }
    }

    @Test("loaded result carries the raw source string")
    func loadedCarriesSource() throws {
        let content = "# Hello\n\nWorld"
        let url = try writeTempFile(name: "source.md", content: content)
        let result = DocumentLoader.load(url)
        guard case let .loaded(_, source) = result else {
            Issue.record("Expected .loaded, got \(result)")
            return
        }
        #expect(source == content)
    }

    @Test("loads a valid .markdown file")
    func loadsMarkdownExtension() throws {
        let url = try writeTempFile(name: "notes.markdown", content: "**bold**")
        let result = DocumentLoader.load(url)
        guard case .loaded = result else {
            Issue.record("Expected .loaded, got \(result)")
            return
        }
    }

    @Test("empty file returns empty blocks array")
    func loadsEmptyFile() throws {
        let url = try writeTempFile(name: "empty.md", content: "")
        let result = DocumentLoader.load(url)
        guard case let .loaded(blocks, _) = result else {
            Issue.record("Expected .loaded, got \(result)")
            return
        }
        #expect(blocks.isEmpty)
    }

    // MARK: - Rejection: bad extension

    @Test("rejects a .txt file")
    func rejectsTxtFile() throws {
        let url = try writeTempFile(name: "notes.txt", content: "Hello")
        let result = DocumentLoader.load(url)
        #expect(result == .rejected(.badExtension))
    }

    // MARK: - Rejection: oversized

    @Test("rejects a file over the size cap")
    func rejectsOversizedFile() throws {
        // Write a file one byte over the cap
        let cap = DocumentURLValidator.maxFileSizeBytes
        let url = try writeTempData(name: "big.md", size: cap + 1)
        let result = DocumentLoader.load(url)
        #expect(result == .rejected(.tooLarge))
    }

    @Test("accepts a file exactly at the size cap")
    func acceptsFileAtCap() throws {
        let cap = DocumentURLValidator.maxFileSizeBytes
        let url = try writeTempData(name: "exact.md", size: cap)
        let result = DocumentLoader.load(url)
        // The data is all 'a' bytes (0x61) — valid UTF-8.
        guard case .loaded = result else {
            Issue.record("Expected .loaded for file exactly at cap, got \(result)")
            return
        }
    }

    @Test("bounded source read rejects a file over the size cap")
    func boundedSourceReadRejectsOversizedFile() throws {
        let url = try writeTempData(
            name: "watched.md",
            size: DocumentURLValidator.maxFileSizeBytes + 1
        )

        #expect(DocumentLoader.readSource(url) == nil)
    }

    @Test("loads a captured source after the file changes again")
    func loadsCapturedSourceAfterFileChangesAgain() throws {
        let url = try writeTempFile(name: "watched.md", content: "# Save A")
        let captured = try #require(DocumentLoader.readSource(url))
        try "# Save B".write(to: url, atomically: true, encoding: .utf8)

        guard case let .loaded(_, source) = DocumentLoader.load(source: captured) else {
            Issue.record("Expected captured source to load")
            return
        }
        #expect(source == "# Save A")
    }

    @MainActor
    @Test("cancellation stops at parse and render boundaries")
    func cancellationStopsAtStageBoundaries() async {
        let parseGate = AsyncGate()
        let renderProbe = RenderProbe()
        let parsing = Task.detached {
            await DocumentLoader.loadAndRender(
                load: {
                    await parseGate.wait()
                    return DocumentLoader.load(source: "# Superseded")
                },
                priorDocument: nil,
                render: { source in
                    await renderProbe.record(source)
                    return AttributedMarkdownBuilder.build(source)
                }
            )
        }
        #expect(await waitUntil { parseGate.waiterCount == 1 })
        parsing.cancel()
        parseGate.open()

        #expect(await parsing.value == nil)
        #expect(await renderProbe.sources.isEmpty)

        let renderGate = AsyncGate()
        let rendering = Task.detached {
            await DocumentLoader.loadAndRender(
                load: { DocumentLoader.load(source: "# Current") },
                priorDocument: nil,
                render: { source in
                    await renderGate.wait()
                    return AttributedMarkdownBuilder.build(source)
                }
            )
        }
        #expect(await waitUntil { renderGate.waiterCount == 1 })
        rendering.cancel()
        renderGate.open()

        #expect(await rendering.value == nil)
    }

    // MARK: - Rejection: non-file URL

    @Test("rejects an https URL")
    func rejectsHttpsURL() {
        let url = URL(string: "https://example.com/doc.md")!
        let result = DocumentLoader.load(url)
        #expect(result == .rejected(.notFileURL))
    }

    // MARK: - Rejection: unreadable / missing

    @Test("returns unreadable for a non-existent file")
    func rejectsNonExistentFile() {
        let url = URL(fileURLWithPath: "/tmp/awesomux-definitely-does-not-exist-\(UUID().uuidString).md")
        let result = DocumentLoader.load(url)
        // Non-existent file → attributes fail → .unreadable
        #expect(result == .rejected(.unreadable))
    }

    @Test("rejects a document not owned by the effective user")
    func rejectsDocumentOwnedByAnotherUser() throws {
        let url = try writeTempFile(name: "untrusted.md", content: "secret")

        let result = DocumentLoader.load(url, effectiveUID: geteuid() + 1)

        #expect(result == .rejected(.unreadable))
    }

    // MARK: - Rejection: non-regular files (A4)

    /// A FIFO named "x.md" must be rejected BEFORE any read attempt.
    /// A synchronous read on a FIFO blocks forever — on the MainActor that is a
    /// permanent UI freeze. The fix: check FileAttributeType == .typeRegular and
    /// reject immediately when the type is anything else.
    @Test("rejects a FIFO — non-regular file must not be read")
    func rejectsFIFO() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("awesomux-fifo-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fifoPath = dir.appendingPathComponent("pipe.md").path
        guard mkfifo(fifoPath, 0o600) == 0 else {
            // If mkfifo fails (rare sandbox restriction), skip rather than fail.
            return
        }

        let url = URL(fileURLWithPath: fifoPath)
        let result = DocumentLoader.load(url)
        // A FIFO must produce .unreadable — never attempt the read.
        #expect(result == .rejected(.unreadable))
    }

    // MARK: - Rejection: symlink bypass (I1)

    /// A `.md`-named symlink pointing at a non-markdown target must be REJECTED.
    /// Before I1, the validator checked `pathExtension` on the unresolved path, so
    /// a `.md` symlink to a `.txt` file would pass extension validation and be read.
    /// The fix resolves symlinks BEFORE validation, exposing the real extension.
    @Test("rejects a .md symlink whose target is a .txt file")
    func rejectsMdSymlinkToTxtTarget() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("awesomux-symlink-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create a real .txt file.
        let target = dir.appendingPathComponent("real.txt")
        try "plain text content".write(to: target, atomically: true, encoding: .utf8)

        // Symlink with a .md name pointing at the .txt file.
        let symlink = dir.appendingPathComponent("tricky.md")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        let result = DocumentLoader.load(symlink)
        // After resolving the symlink the extension is .txt → .badExtension.
        #expect(result == .rejected(.badExtension))
    }

    @Test("loads a symlink to a Markdown target")
    func loadsSymlinkToMarkdownTarget() throws {
        let target = try writeTempFile(name: "target.md", content: "# Linked")
        let symlink = target.deletingLastPathComponent().appending(path: "linked.md")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        let result = DocumentLoader.load(symlink)

        guard case let .loaded(_, source) = result else {
            Issue.record("Expected .loaded, got \(result)")
            return
        }
        #expect(source == "# Linked")
    }

    @Test("invalid UTF-8 returns a deterministic read error")
    func invalidUTF8ReturnsDeterministicReadError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-invalid-utf8-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "invalid.md")
        try Data([0xFF]).write(to: file)

        #expect(
            DocumentLoader.load(file)
                == .readError("The file couldn’t be opened because it isn’t in the correct format.")
        )
    }
}

private actor RenderProbe {
    private(set) var sources: [String] = []

    func record(_ source: String) {
        sources.append(source)
    }
}
