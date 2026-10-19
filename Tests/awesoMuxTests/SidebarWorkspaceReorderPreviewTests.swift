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
