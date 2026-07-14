import AwesoMuxTestSupport
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("MarkdownDocumentWriter")
struct MarkdownDocumentWriterTests {
    @Test("writes a change when the rendered source is current")
    func writesCurrentSource() throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-markdown-write")
        let file = directory.url.appending(path: "plan.md")
        try Data("original".utf8).write(to: file)

        let result = MarkdownDocumentWriter.applyIfCurrent(
            at: file,
            expectedSource: "original",
            transform: { $0 + " updated" }
        )

        #expect(result == .written(source: "original updated"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "original updated")
    }

    @Test("refuses a write when the rendered source is stale")
    func refusesStaleSource() throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-markdown-write")
        let file = directory.url.appending(path: "plan.md")
        try Data("external edit".utf8).write(to: file)

        let result = MarkdownDocumentWriter.applyIfCurrent(
            at: file,
            expectedSource: "rendered source",
            transform: { $0 + " annotation" }
        )

        #expect(result == .conflict)
        #expect(try String(contentsOf: file, encoding: .utf8) == "external edit")
    }

    @Test("preserves an intervening write before replacement")
    func preservesInterveningWrite() throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-markdown-write")
        let file = directory.url.appending(path: "plan.md")
        try Data("original".utf8).write(to: file)

        let result = MarkdownDocumentWriter.applyIfCurrent(
            at: file,
            expectedSource: "original",
            transform: { $0 + " annotation" },
            beforeReplacement: {
                try Data("external edit".utf8).write(to: file)
            }
        )

        #expect(result == .conflict)
        #expect(try String(contentsOf: file, encoding: .utf8) == "external edit")
    }

    @Test("refuses an unreadable input")
    func refusesUnreadableInput() throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-markdown-write")
        let missing = directory.url.appending(path: "missing.md")

        let result = MarkdownDocumentWriter.applyIfCurrent(
            at: missing,
            expectedSource: "original",
            transform: { $0 + " annotation" }
        )

        #expect(result == .unreadable)
    }

    @Test("refuses an oversized input")
    func refusesOversizedInput() throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-markdown-write")
        let file = directory.url.appending(path: "oversized.md")
        _ = FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(DocumentURLValidator.maxFileSizeBytes + 1))
        try handle.close()

        let result = MarkdownDocumentWriter.applyIfCurrent(
            at: file,
            expectedSource: "",
            transform: { $0 + " annotation" }
        )

        #expect(result == .unreadable)
    }

    @Test("replaces a deliberate symlink target without replacing the symlink")
    func replacesResolvedSymlinkTarget() throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-markdown-write")
        let target = directory.url.appending(path: "target.md")
        let symlink = directory.url.appending(path: "plan.md")
        try Data("original".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            atPath: symlink.path,
            withDestinationPath: target.lastPathComponent
        )

        let result = MarkdownDocumentWriter.applyIfCurrent(
            at: symlink,
            expectedSource: "original",
            transform: { $0 + " updated" }
        )

        #expect(result == .written(source: "original updated"))
        #expect(try String(contentsOf: target, encoding: .utf8) == "original updated")
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path)
                == target.lastPathComponent
        )
    }
}
