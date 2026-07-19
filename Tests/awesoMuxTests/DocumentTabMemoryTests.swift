import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite struct DocumentTabMemoryTests {
    private func makeTab(path: String) -> DocumentPane {
        DocumentPane(
            fileURL: URL(fileURLWithPath: path),
            title: (path as NSString).lastPathComponent
        )
    }

    private func makeRender(source: String) -> DocumentTabMemory.Render {
        let renderedDocument = makeRenderedDocument(source: source)
        return DocumentTabMemory.Render(
            loadResult: .loaded([], source: source, snapshot: nil),
            renderedDoc: renderedDocument
        )
    }

    private func makeRenderedDocument(source: String) -> RenderedDocument {
        RenderedDocument(
            source: source,
            runs: [],
            annotations: [],
            taskProgress: TaskProgress(done: 0, total: 0)
        )
    }

    @Test func storedRenderAndAnchorReadBackForSameTab() {
        var memory = DocumentTabMemory()
        let tab = makeTab(path: "/tmp/a.md")
        memory.storeRender(makeRender(source: "a"), for: tab)
        memory.storeScrollAnchor(42, for: tab)
        #expect(memory.render(for: tab)?.loadResult == .loaded([], source: "a", snapshot: nil))
        #expect(memory.scrollAnchor(for: tab) == 42)
    }

    @Test func successfulRenderSeedDropsParsedBlocksAndSnapshot() throws {
        var memory = DocumentTabMemory()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentTabMemoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fileURL = temporaryDirectory.appendingPathComponent("a.md")
        try Data("a".utf8).write(to: fileURL)
        let tab = makeTab(path: fileURL.path)
        let loadedResult = DocumentLoader.load(fileURL)
        guard case let .loaded(parsedBlocks, _, loadedSnapshot) = loadedResult else {
            Issue.record("Expected the fixture document to load")
            return
        }
        #expect(!parsedBlocks.isEmpty)
        #expect(loadedSnapshot != nil)

        memory.storeRender(
            DocumentTabMemory.Render(
                loadResult: loadedResult,
                renderedDoc: makeRenderedDocument(source: "a")
            ),
            for: tab
        )

        let storedRender = memory.render(for: tab)
        #expect(storedRender?.renderedDoc?.source == "a")
        guard case let .loaded(blocks, source, snapshot) = storedRender?.loadResult else {
            Issue.record("Expected a successful cached seed")
            return
        }
        #expect(blocks.isEmpty)
        #expect(source == "a")
        #expect(snapshot == nil)
    }

    @Test func failureSeedsPreserveOnlyTheirDisplayDetails() {
        var memory = DocumentTabMemory()
        let failures: [DocumentLoader.LoadResult] = [
            .rejected(.tooLarge),
            .readError("The file couldn’t be read."),
        ]

        for (index, failure) in failures.enumerated() {
            let tab = makeTab(path: "/tmp/failure-\(index).md")
            memory.storeRender(
                DocumentTabMemory.Render(loadResult: failure, renderedDoc: nil),
                for: tab
            )
            #expect(memory.render(for: tab)?.loadResult == failure)
            #expect(memory.render(for: tab)?.renderedDoc == nil)
        }
    }

    @Test func nilAnchorClearsAStoredOne() {
        var memory = DocumentTabMemory()
        let tab = makeTab(path: "/tmp/a.md")
        memory.storeScrollAnchor(42, for: tab)
        memory.storeScrollAnchor(nil, for: tab)
        #expect(memory.scrollAnchor(for: tab) == nil)
    }

    @Test func inPlaceFileReplacementInvalidatesTheOldEntry() {
        // The inline Files browser swaps a tab's file while keeping its id —
        // the old file's render and scroll anchor must not leak onto the new one.
        var memory = DocumentTabMemory()
        let tab = makeTab(path: "/tmp/a.md")
        memory.storeRender(makeRender(source: "a"), for: tab)
        memory.storeScrollAnchor(42, for: tab)

        var replaced = tab
        replaced.fileURL = URL(fileURLWithPath: "/tmp/b.md")
        #expect(memory.render(for: replaced) == nil)
        #expect(memory.scrollAnchor(for: replaced) == nil)

        // Writing under the new path starts a fresh entry; the old path's
        // memory does not resurface even though the tab id matches.
        memory.storeScrollAnchor(7, for: replaced)
        #expect(memory.scrollAnchor(for: replaced) == 7)
        #expect(memory.render(for: replaced) == nil)
    }

    @Test func pruneDropsClosedTabsAndKeepsOpenOnes() {
        var memory = DocumentTabMemory()
        let kept = makeTab(path: "/tmp/a.md")
        let closed = makeTab(path: "/tmp/b.md")
        memory.storeRender(makeRender(source: "a"), for: kept)
        memory.storeScrollAnchor(1, for: kept)
        memory.storeRender(makeRender(source: "b"), for: closed)

        memory.prune(keeping: [kept])
        #expect(memory.render(for: kept) != nil)
        #expect(memory.scrollAnchor(for: kept) == 1)
        #expect(memory.render(for: closed) == nil)
    }

    @Test func pruneDropsEntriesWhoseTabNowShowsADifferentFile() {
        var memory = DocumentTabMemory()
        let tab = makeTab(path: "/tmp/a.md")
        memory.storeRender(makeRender(source: "a"), for: tab)

        var replaced = tab
        replaced.fileURL = URL(fileURLWithPath: "/tmp/b.md")
        memory.prune(keeping: [replaced])
        #expect(memory.render(for: tab) == nil)
    }
}
