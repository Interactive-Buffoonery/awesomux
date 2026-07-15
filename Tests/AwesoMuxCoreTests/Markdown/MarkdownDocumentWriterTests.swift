import AwesoMuxTestSupport
import Darwin
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("MarkdownDocumentCommitter")
struct MarkdownDocumentWriterTests {
    @Test("writes a change when the rendered source is current")
    func writesCurrentSource() throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-markdown-write")
        let file = directory.url.appending(path: "plan.md")
        try Data("original".utf8).write(to: file)

        let result = MarkdownDocumentCommitter.commitObserved(
            at: file,
            renderedSource: "original",
            transform: { $0 + " updated" }
        )

        #expect(result == .committed(source: "original updated"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "original updated")
    }

    @Test("refuses a write when the rendered source is stale")
    func refusesStaleSource() throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-markdown-write")
        let file = directory.url.appending(path: "plan.md")
        try Data("external edit".utf8).write(to: file)

        let result = MarkdownDocumentCommitter.commitObserved(
            at: file,
            renderedSource: "rendered source",
            transform: { $0 + " annotation" }
        )

        #expect(result == .observedConflict)
        #expect(try String(contentsOf: file, encoding: .utf8) == "external edit")
    }

    @Test("retries a preserved annotation draft against a reloaded stable id")
    func retriesAfterConflictReload() throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-markdown-write")
        let file = directory.url.appending(path: "plan.md")
        let rendered = "<mark>a</mark><!-- AMX id=q3k7 by=user: old -->"
        let reloaded = "heading\n\n<mark>a</mark><!-- AMX id=q3k7 by=user: old -->"
        try Data(reloaded.utf8).write(to: file)

        let conflict = MarkdownDocumentCommitter.commitObserved(
            at: file,
            renderedSource: rendered,
            transform: { source in
                PlanAnnotationWriter.updatingAnnotation(id: "q3k7", in: source) {
                    $0.payload = "preserved draft"
                }
            }
        )
        #expect(conflict == .observedConflict)

        let retry = MarkdownDocumentCommitter.commitObserved(
            at: file,
            renderedSource: reloaded,
            transform: { source in
                PlanAnnotationWriter.updatingAnnotation(id: "q3k7", in: source) {
                    $0.payload = "preserved draft"
                }
            }
        )

        #expect(
            retry
                == .committed(
                    source: "heading\n\n<mark>a</mark><!-- AMX id=q3k7 by=user: preserved draft -->"
                ))
    }

    @Test("preserves an intervening write observed before replacement")
    func preservesInterveningWrite() throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-markdown-write")
        let file = directory.url.appending(path: "plan.md")
        try Data("original".utf8).write(to: file)

        let result = MarkdownDocumentCommitter.commitObserved(
            at: file,
            renderedSource: "original",
            transform: { $0 + " annotation" },
            beforeRecheck: {
                try Data("external edit".utf8).write(to: file)
            }
        )

        #expect(result == .observedConflict)
        #expect(try String(contentsOf: file, encoding: .utf8) == "external edit")
    }

    @Test("refuses an unreadable input")
    func refusesUnreadableInput() throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-markdown-write")
        let missing = directory.url.appending(path: "missing.md")

        let result = MarkdownDocumentCommitter.commitObserved(
            at: missing,
            renderedSource: "original",
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

        let result = MarkdownDocumentCommitter.commitObserved(
            at: file,
            renderedSource: "",
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

        let result = MarkdownDocumentCommitter.commitObserved(
            at: symlink,
            renderedSource: "original",
            transform: { $0 + " updated" }
        )

        #expect(result == .committed(source: "original updated"))
        #expect(try String(contentsOf: target, encoding: .utf8) == "original updated")
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path)
                == target.lastPathComponent
        )
    }

    @Test("refuses a write when the input symlink is retargeted before commit")
    func refusesRetargetedSymlink() throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-markdown-write")
        let firstTarget = directory.url.appending(path: "first.md")
        let secondTarget = directory.url.appending(path: "second.md")
        let symlink = directory.url.appending(path: "plan.md")
        try Data("original".utf8).write(to: firstTarget)
        try Data("other".utf8).write(to: secondTarget)
        try FileManager.default.createSymbolicLink(
            atPath: symlink.path,
            withDestinationPath: firstTarget.lastPathComponent
        )

        let result = MarkdownDocumentCommitter.commitObserved(
            at: symlink,
            renderedSource: "original",
            transform: { $0 + " updated" },
            beforeRecheck: {
                try FileManager.default.removeItem(at: symlink)
                try FileManager.default.createSymbolicLink(
                    atPath: symlink.path,
                    withDestinationPath: secondTarget.lastPathComponent
                )
            }
        )

        #expect(result == .observedConflict)
        #expect(try String(contentsOf: firstTarget, encoding: .utf8) == "original")
        #expect(try String(contentsOf: secondTarget, encoding: .utf8) == "other")
    }

    @Test("refuses a same-byte replacement of the resolved target")
    func refusesResolvedTargetSubstitution() throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-markdown-write")
        let file = directory.url.appending(path: "plan.md")
        let replacement = directory.url.appending(path: "replacement.md")
        try Data("original".utf8).write(to: file)
        try Data("original".utf8).write(to: replacement)

        let result = MarkdownDocumentCommitter.commitObserved(
            at: file,
            renderedSource: "original",
            transform: { $0 + " updated" },
            beforeRecheck: {
                try FileManager.default.removeItem(at: file)
                try FileManager.default.moveItem(at: replacement, to: file)
            }
        )

        #expect(result == .observedConflict)
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
    }

    @Test("refuses output above the document size cap")
    func refusesOversizedOutput() throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-markdown-write")
        let file = directory.url.appending(path: "plan.md")
        try Data().write(to: file)
        let oversized = String(
            repeating: "a",
            count: DocumentURLValidator.maxFileSizeBytes + 1
        )

        let result = MarkdownDocumentCommitter.commitObserved(
            at: file,
            renderedSource: "",
            transform: { _ in oversized }
        )

        #expect(result == .outputTooLarge)
        #expect(try Data(contentsOf: file).isEmpty)
    }

    @Test("accepts output exactly at the document size cap")
    func acceptsMaximumOutput() throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-markdown-write")
        let file = directory.url.appending(path: "plan.md")
        try Data().write(to: file)
        let maximum = String(
            repeating: "a",
            count: DocumentURLValidator.maxFileSizeBytes
        )

        let result = MarkdownDocumentCommitter.commitObserved(
            at: file,
            renderedSource: "",
            transform: { _ in maximum }
        )

        #expect(result == .committed(source: maximum))
        #expect(try Data(contentsOf: file).count == DocumentURLValidator.maxFileSizeBytes)
    }

    @Test("returns useful write error detail")
    func returnsWriteErrorDetail() throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-markdown-write")
        let file = directory.url.appending(path: "plan.md")
        try Data("original".utf8).write(to: file)

        let result = MarkdownDocumentCommitter.commitObserved(
            at: file,
            renderedSource: "original",
            transform: { $0 + " updated" },
            beforeRecheck: {},
            write: { _, _ in
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(ENOSPC),
                    userInfo: [NSLocalizedDescriptionKey: "The disk is full."]
                )
            }
        )

        #expect(result == .failed(.write(message: "The disk is full.")))
    }

    @Test("returns useful coordination error detail")
    func returnsCoordinationErrorDetail() throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-markdown-write")
        let file = directory.url.appending(path: "plan.md")
        try Data("original".utf8).write(to: file)

        let result = MarkdownDocumentCommitter.commitObserved(
            at: file,
            renderedSource: "original",
            transform: { $0 + " updated" },
            beforeRecheck: {},
            coordinate: { _, _ in
                NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileWriteUnknownError,
                    userInfo: [NSLocalizedDescriptionKey: "Another writer refused coordination."]
                )
            }
        )

        #expect(
            result
                == .failed(
                    .coordination(
                        message: "Another writer refused coordination."
                    )))
    }
}
