import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct DocumentPaneTests {
    @Test func codableRoundTrip() throws {
        let pane = DocumentPane(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            fileURL: URL(fileURLWithPath: "/tmp/notes.md"),
            title: "notes.md"
        )
        let data = try JSONEncoder().encode(pane)
        let decoded = try JSONDecoder().decode(DocumentPane.self, from: data)
        #expect(decoded == pane)
    }

    @Test func decodesSnapshotsWithLegacyScrollOffset() throws {
        let data = Data(
            #"{"id":"11111111-1111-1111-1111-111111111111","fileURL":"file:///tmp/notes.md","title":"notes.md","scrollOffset":12.5}"#.utf8
        )
        let pane = try JSONDecoder().decode(DocumentPane.self, from: data)
        #expect(pane.fileURL == URL(fileURLWithPath: "/tmp/notes.md"))
        #expect(pane.title == "notes.md")
    }

    @Test func defaultsAreStable() {
        let pane = DocumentPane(fileURL: URL(fileURLWithPath: "/tmp/a.md"), title: "a.md")
        #expect(pane.remoteSnapshotOrigin == nil)
        #expect(!pane.isReadOnlySnapshot)
    }

    @Test func remoteSnapshotRoundTrips() throws {
        let pane = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/cache.md"),
            title: "cache.md",
            remoteSnapshotOrigin: "me@example.com:/repo/cache.md"
        )

        let data = try JSONEncoder().encode(pane)
        let decoded = try JSONDecoder().decode(DocumentPane.self, from: data)

        #expect(decoded == pane)
        #expect(decoded.isReadOnlySnapshot)
    }
}

@Suite struct DocumentGroupAdjacentTabTests {
    private func makeGroup(count: Int, selectedIndex: Int) -> DocumentGroup {
        let tabs = (0..<count).map { index in
            DocumentPane(fileURL: URL(fileURLWithPath: "/tmp/\(index).md"), title: "\(index).md")
        }
        return DocumentGroup(tabs: tabs, selectedTabID: tabs[selectedIndex].id)
    }

    @Test func nextFromMiddleReturnsFollowingTab() {
        let group = makeGroup(count: 3, selectedIndex: 1)
        #expect(group.adjacentTabID(offset: 1) == group.tabs[2].id)
    }

    @Test func previousFromMiddleReturnsPrecedingTab() {
        let group = makeGroup(count: 3, selectedIndex: 1)
        #expect(group.adjacentTabID(offset: -1) == group.tabs[0].id)
    }

    @Test func nextFromLastWrapsToFirst() {
        let group = makeGroup(count: 3, selectedIndex: 2)
        #expect(group.adjacentTabID(offset: 1) == group.tabs[0].id)
    }

    @Test func previousFromFirstWrapsToLast() {
        let group = makeGroup(count: 3, selectedIndex: 0)
        #expect(group.adjacentTabID(offset: -1) == group.tabs[2].id)
    }

    @Test func singleTabHasNoAdjacentTab() {
        let group = makeGroup(count: 1, selectedIndex: 0)
        #expect(group.adjacentTabID(offset: 1) == nil)
        #expect(group.adjacentTabID(offset: -1) == nil)
    }
}
