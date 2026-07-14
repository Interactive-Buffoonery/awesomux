import Foundation
import Testing

@Suite("Sidebar split visibility ownership")
struct SidebarSplitVisibilityOwnershipTests {
    @Test("representable updates never enact runtime visibility")
    func updatePathHasNoVisibilitySetter() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let root = testURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/awesoMux/Views/SidebarSplitView.swift"),
            encoding: .utf8
        )
        let update = try #require(
            source.split(separator: "func updateNSViewController", maxSplits: 1).last
        )
        let body = try #require(update.split(separator: "\n    }", maxSplits: 1).first)
        #expect(!body.contains("setSidebarHidden"))
        #expect(!body.contains("setSidebarVisible"))
        #expect(!body.contains("setVisibility"))
        #expect(!body.contains("setOverlayVisible"))
        #expect(!body.contains("setPersistentVisible"))
        #expect(!body.contains("setEdgeTrackingEnabled"))
        #expect(!body.contains("setSidebarPosition"))
        #expect(!body.contains("terminalMinimumWidth ="))
    }
}
