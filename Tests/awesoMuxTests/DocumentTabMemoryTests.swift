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
            loadResult: .loaded(source: source, snapshot: nil),
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
        memory.storeCopyMode(true, for: tab)
        #expect(memory.render(for: tab)?.loadResult == .loaded(source: "a", snapshot: nil))
        #expect(memory.scrollAnchor(for: tab) == 42)
        #expect(memory.isCopyMode(for: tab))
    }

    @Test func successfulRenderSeedDropsTheFileSnapshot() throws {
        var memory = DocumentTabMemory()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentTabMemoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fileURL = temporaryDirectory.appendingPathComponent("a.md")
        try Data("a".utf8).write(to: fileURL)
        let tab = makeTab(path: fileURL.path)
        let loadedResult = DocumentLoader.load(fileURL)
        guard case let .loaded(_, loadedSnapshot) = loadedResult else {
            Issue.record("Expected the fixture document to load")
            return
        }
        #expect(loadedSnapshot != nil, "premise: a live load must carry a snapshot to drop")

        memory.storeRender(
            DocumentTabMemory.Render(
                loadResult: loadedResult,
                renderedDoc: makeRenderedDocument(source: "a")
            ),
            for: tab
        )

        let storedRender = memory.render(for: tab)
        #expect(storedRender?.renderedDoc?.source == "a")
        guard case let .loaded(source, snapshot) = storedRender?.loadResult else {
            Issue.record("Expected a successful cached seed")
            return
        }
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
        memory.storeCopyMode(true, for: tab)

        var replaced = tab
        replaced.fileURL = URL(fileURLWithPath: "/tmp/b.md")
        #expect(memory.render(for: replaced) == nil)
        #expect(memory.scrollAnchor(for: replaced) == nil)
        #expect(!memory.isCopyMode(for: replaced))

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
        memory.storeCopyMode(true, for: kept)
        memory.storeRender(makeRender(source: "b"), for: closed)

        memory.prune(keeping: [kept])
        #expect(memory.render(for: kept) != nil)
        #expect(memory.scrollAnchor(for: kept) == 1)
        #expect(memory.isCopyMode(for: kept))
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

    @Test func collapsedSectionsToggleAndReadBackForTheSamePath() {
        var memory = DocumentTabMemory()
        let tab = makeTab(path: "/tmp/c.md")
        #expect(memory.collapsedSections(for: tab).isEmpty)
        memory.toggleSection("a.swift", for: tab)
        memory.toggleSection("b.swift", for: tab)
        memory.toggleSection("a.swift", for: tab)
        #expect(memory.collapsedSections(for: tab) == ["b.swift"])
        memory.setCollapsedSections(["x", "y"], for: tab)
        #expect(memory.collapsedSections(for: tab) == ["x", "y"])
    }

    @Test func collapsedSectionsDropWhenTheTabShowsAnotherFile() {
        var memory = DocumentTabMemory()
        let tab = makeTab(path: "/tmp/d.md")
        memory.toggleSection("a.swift", for: tab)
        var moved = tab
        moved.fileURL = URL(fileURLWithPath: "/tmp/other.md")
        #expect(memory.collapsedSections(for: moved).isEmpty)
        memory.prune(keeping: [moved])
        // Prune drops the view-local entry, not the fold state: folds are pinned
        // to (id, path) and outlive the group view so a workspace switch keeps
        // them. Asking for the old path again gets the old folds back.
        #expect(memory.collapsedSections(for: tab) == ["a.swift"])
    }

    @Test func collapsedSectionsSurviveARenderStoreForTheSamePath() {
        var memory = DocumentTabMemory()
        let tab = makeTab(path: "/tmp/e.md")
        memory.toggleSection("a.swift", for: tab)
        memory.storeRender(makeRender(source: "refreshed"), for: tab)
        #expect(memory.collapsedSections(for: tab) == ["a.swift"])
    }

    @Test func collapsedKeysKeyedByPathSurviveAStatusSuffixChange() {
        // Keyed on the path only (BranchDiffSectionIndex.keyText), so the fold set
        // stored while the file was `— new file` still applies after a commit.
        let before = BranchDiffSectionIndex(document: AttributedMarkdownBuilder.build("## a.swift — _new file_\n\n```diff\n+x\n```\n"))
        let after = BranchDiffSectionIndex(document: AttributedMarkdownBuilder.build("## a.swift\n\n```diff\n+x\n```\n"))
        var memory = DocumentTabMemory()
        let tab = makeTab(path: "/tmp/g.md")
        memory.toggleSection(before.keys[0], for: tab)
        #expect(memory.collapsedSections(for: tab).contains(after.keys[0]))
    }

    @Test func collapsedSectionsOutliveTheMemoryStructForTheSamePath() {
        // A workspace switch rebuilds the group view and its @State memory; the
        // folds must come back for the same tab id and path, and not for another path.
        let tab = makeTab(path: "/tmp/h.md")
        var first = DocumentTabMemory()
        first.toggleSection("a.swift", for: tab)
        let second = DocumentTabMemory()
        #expect(second.collapsedSections(for: tab) == ["a.swift"])
        let moved = DocumentPane(id: tab.id, fileURL: URL(fileURLWithPath: "/tmp/other.md"), title: "other.md")
        #expect(second.collapsedSections(for: moved).isEmpty)
    }

    @Test func renderCarriesTheSectionIndexItWasGiven() {
        let doc = AttributedMarkdownBuilder.build("## f\n\n```diff\n+a\n```\n")
        let index = BranchDiffSectionIndex(document: doc)
        let render = DocumentTabMemory.Render(loadResult: .loaded(source: doc.source, snapshot: nil), renderedDoc: doc, sectionIndex: index)
        var memory = DocumentTabMemory()
        let tab = makeTab(path: "/tmp/f.md")
        memory.storeRender(render, for: tab)
        #expect(memory.sectionIndex(for: tab)?.keys == ["f"])
    }
}
