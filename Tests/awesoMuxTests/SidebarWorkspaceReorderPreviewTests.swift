import CoreGraphics
import Testing
@testable import awesoMux

@Suite("Sidebar workspace reorder preview")
struct SidebarWorkspaceReorderPreviewTests {
    private let ids = ["a", "b", "c", "d"]
    private let frames: [String: CGRect] = [
        "a": CGRect(x: 0, y: 0, width: 200, height: 30),
        "b": CGRect(x: 0, y: 35, width: 200, height: 60),
        "c": CGRect(x: 0, y: 100, width: 200, height: 40),
        "d": CGRect(x: 0, y: 145, width: 200, height: 20),
    ]

    @Test func downwardMoveClosesSourceAndOpensDestination() throws {
        let preview = try #require(
            SidebarWorkspaceReorderPreview(
                sourceID: "b", insertionIndex: 4, orderedIDs: ids, frames: frames, spacing: 5
            ))
        #expect(preview.offsets == ["c": -65, "d": -65])
        #expect(preview.gapFrame == CGRect(x: 0, y: 105, width: 200, height: 60))
        #expect(frames["b"]?.minY == 35)
    }

    @Test func upwardMoveOpensGapAboveVariableHeightRows() throws {
        let preview = try #require(
            SidebarWorkspaceReorderPreview(
                sourceID: "d", insertionIndex: 1, orderedIDs: ids, frames: frames, spacing: 5
            ))
        #expect(preview.offsets == ["b": 25, "c": 25])
        #expect(preview.gapFrame == CGRect(x: 0, y: 35, width: 200, height: 20))
    }

    @Test(arguments: [nil, 1, 2])
    func noOpKeepsGapAtSource(insertionIndex: Int?) throws {
        let preview = try #require(
            SidebarWorkspaceReorderPreview(
                sourceID: "b", insertionIndex: insertionIndex, orderedIDs: ids, frames: frames, spacing: 5
            ))
        #expect(preview.offsets.isEmpty)
        #expect(preview.gapFrame == frames["b"])
    }

    @Test func missingSourceOrIncompleteLayoutDoesNotGuess() {
        #expect(
            SidebarWorkspaceReorderPreview(
                sourceID: "other-group", insertionIndex: 0, orderedIDs: ids, frames: frames, spacing: 5
            ) == nil)
        #expect(
            SidebarWorkspaceReorderPreview(
                sourceID: "b", insertionIndex: 4, orderedIDs: ids, frames: ["b": frames["b"]!], spacing: 5
            ) == nil)
    }

    @Test func pointerInsideTheVisibleGapKeepsItsDestination() {
        #expect(
            SidebarWorkspaceReorderPreview.insertionIndex(
                forDropY: 120, sourceID: "b", currentInsertionIndex: 4, orderedIDs: ids, frames: frames
            ) == 4)
        #expect(
            SidebarWorkspaceReorderPreview.insertionIndex(
                forDropY: 104, sourceID: "b", currentInsertionIndex: 4, orderedIDs: ids, frames: frames
            ) == 3)
        #expect(
            SidebarWorkspaceReorderPreview.insertionIndex(
                forDropY: 90, sourceID: "b", currentInsertionIndex: 3, orderedIDs: ids, frames: frames
            ) == 3)
        #expect(
            SidebarWorkspaceReorderPreview.insertionIndex(
                forDropY: 50, sourceID: "b", currentInsertionIndex: nil, orderedIDs: ids, frames: frames
            ) == 1)
        #expect(
            SidebarWorkspaceReorderPreview.insertionIndex(
                forDropY: 500, sourceID: "b", currentInsertionIndex: nil, orderedIDs: ids, frames: frames
            ) == 4)
    }
}
