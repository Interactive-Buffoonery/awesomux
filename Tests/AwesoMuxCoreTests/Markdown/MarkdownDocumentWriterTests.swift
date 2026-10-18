import AwesoMuxTestSupport
import Darwin
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("MarkdownDocumentCommitter")
struct MarkdownDocumentWriterTests {
    private func snapshot(at file: URL) throws -> MarkdownDocumentSnapshot {
        guard case let .loaded(_, snapshot) = DocumentLoader.load(file), let snapshot else {
            throw CocoaError(.fileReadUnknown)
        }
        return snapshot
    }

    @Test(
        arguments: [
            ("rendered source", "external edit", nil),
            ("caf\u{00E9}", "cafe\u{0301}", nil),
            (
                "<mark>a</mark><!-- AMX id=q3k7 by=user: old -->",
                "heading\n\n<mark>a</mark><!-- AMX id=q3k7 by=user: old -->",
                "heading\n\n<mark>a</mark><!-- AMX id=q3k7 by=user: preserved draft -->"
            ),
        ] as [(String, String, String?)])
    func staleSources(rendered: String, onDisk: String, retryOutput: String?) throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-markdown-write")
        let file = directory.url.appending(path: "plan.md")
        try Data(onDisk.utf8).write(to: file)
        let transform: (String) -> String? = { source in
            if retryOutput != nil {
                return PlanAnnotationWriter.updatingAnnotation(id: "q3k7", in: source) { $0.payload = "preserved draft" }
            }
            return source + " annotation"
        }
        let result = MarkdownDocumentCommitter.commitObserved(at: file, renderedSource: rendered, transform: transform)
        #expect(result == .observedConflict)
        #expect(try Data(contentsOf: file) == Data(onDisk.utf8))
        if let retryOutput {
            let retry = MarkdownDocumentCommitter.commitObserved(at: file, renderedSource: onDisk, transform: transform)
            #expect(retry == .committed(source: retryOutput))
            #expect(try Data(contentsOf: file) == Data(retryOutput.utf8))
        }
    }

    enum Mutation: CaseIterable { case externalEdit, replacement, retarget }

    @Test(arguments: Mutation.allCases)
    func mutationsBeforeRecheck(mutation: Mutation) throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-markdown-write")
        let first = directory.url.appending(path: "first.md")
        let second = directory.url.appending(path: "second.md")
        let symlink = directory.url.appending(path: "plan.md")
        try Data("original".utf8).write(to: first)
        try Data("original".utf8).write(to: second)
        if mutation == .retarget {
            try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: first.lastPathComponent)
        }
        let result = MarkdownDocumentCommitter.commitObserved(
            at: mutation == .retarget ? symlink : first,
            renderedSource: "original", transform: { $0 + " annotation" },
            beforeRecheck: {
                switch mutation {
                case .externalEdit:
                    try Data("external edit".utf8).write(to: first)
                case .replacement:
                    try FileManager.default.removeItem(at: first)
                    try FileManager.default.moveItem(at: second, to: first)
                case .retarget:
                    try FileManager.default.removeItem(at: symlink)
                    try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: second.lastPathComponent)
                }
            }
        )
        #expect(result == .observedConflict)
        #expect(try Data(contentsOf: first) == Data((mutation == .externalEdit ? "external edit" : "original").utf8))
        if mutation != .replacement {
            #expect(try Data(contentsOf: second) == Data("original".utf8))
        } else {
            #expect(!FileManager.default.fileExists(atPath: second.path))
        }
        if mutation == .retarget {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path) == second.lastPathComponent)
        }
    }

    @Test(arguments: [0, 1])
    func outputCaps(extraBytes: Int) throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-markdown-write")
        let file = directory.url.appending(path: "plan.md")
        try Data().write(to: file)
        let output = String(repeating: "a", count: DocumentURLValidator.maxFileSizeBytes + extraBytes)
        let result = MarkdownDocumentCommitter.commitObserved(at: file, renderedSource: "", transform: { _ in output })
        #expect(result == (extraBytes == 0 ? .committed(source: output) : .outputTooLarge))
        #expect(try Data(contentsOf: file) == (extraBytes == 0 ? Data(output.utf8) : Data()))
    }

    @Test("preserves file mode and extended attributes")
    func preservesMetadata() throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-markdown-write")
        let file = directory.url.appending(path: "plan.md")
        try Data("original".utf8).write(to: file)
        #expect(chmod(file.path, 0o640) == 0)
        let attributeName = "com.awesomux.test"
        let attributeValue = Array("kept".utf8)
        #expect(
            attributeValue.withUnsafeBytes {
                setxattr(
                    file.path,
                    attributeName,
                    $0.baseAddress,
                    $0.count,
                    0,
                    0
                )
            } == 0
        )

        let result = MarkdownDocumentCommitter.commitObserved(
            at: file,
            observed: try snapshot(at: file),
            transform: { $0 + " updated" }
        )

        #expect(result == .committed(source: "original updated"))
        #expect(try Data(contentsOf: file) == Data("original updated".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        let size = getxattr(file.path, attributeName, nil, 0, 0, 0)
        var bytes = [UInt8](repeating: 0, count: size)
        #expect(getxattr(file.path, attributeName, &bytes, size, 0, 0) == size)
        #expect(bytes == attributeValue)
    }

    @Test("creates the replacement temp exclusively at owner-only mode before writing")
    func createsOwnerOnlyEmptyTempBeforeWriting() throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-markdown-write")
        let file = directory.url.appending(path: "plan.md")
        try Data("original".utf8).write(to: file)
        var inspected = false

        try MarkdownDocumentCommitter.replacePreservingMetadata(
            Data("updated".utf8),
            at: file
        ) { temporaryURL in
            inspected = true
            let attributes = try FileManager.default.attributesOfItem(
                atPath: temporaryURL.path
            )
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect(try Data(contentsOf: temporaryURL).isEmpty)
        }

        #expect(inspected)
        #expect(try String(contentsOf: file, encoding: .utf8) == "updated")
    }

    @Test("binds save to the render-time inode even when replacement bytes match")
    func refusesSameByteReplacementSinceRender() throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-markdown-write")
        let file = directory.url.appending(path: "plan.md")
        let replacement = directory.url.appending(path: "replacement.md")
        try Data("original".utf8).write(to: file)
        let rendered = try snapshot(at: file)
        try Data("original".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: replacement, to: file)

        let result = MarkdownDocumentCommitter.commitObserved(
            at: file,
            observed: rendered,
            transform: { $0 + " updated" }
        )

        #expect(result == .observedConflict)
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
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

    @Test("reports when the input crosses the size cap during commit")
    func reportsInputGrowingPastCap() throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-markdown-write")
        let file = directory.url.appending(path: "plan.md")
        try Data("original".utf8).write(to: file)
        var didWrite = false

        let result = MarkdownDocumentCommitter.commitObserved(
            at: file,
            renderedSource: "original",
            transform: { $0 + " annotation" },
            beforeRecheck: {
                let handle = try FileHandle(forWritingTo: file)
                try handle.truncate(
                    atOffset: UInt64(DocumentURLValidator.maxFileSizeBytes + 1)
                )
                try handle.close()
            },
            write: { _, _ in didWrite = true }
        )

        #expect(result == .inputTooLarge)
        #expect(!didWrite)
        #expect(try Data(contentsOf: file).count == DocumentURLValidator.maxFileSizeBytes + 1)
    }
}
