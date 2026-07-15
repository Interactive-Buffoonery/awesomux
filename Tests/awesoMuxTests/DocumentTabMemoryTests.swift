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
        DocumentTabMemory.Render(
            loadResult: .loaded([], source: source, snapshot: nil),
            renderedDoc: nil
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
