import Foundation
import Testing
@testable import awesoMux

@Suite("Sidebar native workspace drag payload")
struct SidebarWorkspaceDragPayloadTests {
    @Test func onlyTheCurrentWorkspaceDragDecodesSynchronously() throws {
        let sessionID = UUID()
        let dragID = UUID()
        let data = try JSONEncoder().encode(WorkspaceDragItem(sessionID: sessionID, dragID: dragID))
        #expect(WorkspaceDragItem(data: data, expectedDragID: dragID)?.sessionID == sessionID)
        #expect(WorkspaceDragItem(data: data, expectedDragID: UUID()) == nil)
        let groupData = try JSONEncoder().encode(WorkspaceGroupDragItem(groupID: UUID(), dragID: dragID))
        #expect(WorkspaceDragItem(data: groupData, expectedDragID: dragID) == nil)
        #expect(WorkspaceDragItem(data: Data(), expectedDragID: dragID) == nil)
    }
}
