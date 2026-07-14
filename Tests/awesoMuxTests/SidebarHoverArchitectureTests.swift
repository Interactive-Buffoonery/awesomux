import Foundation
import Testing

@Suite("Sidebar hover architecture")
struct SidebarHoverArchitectureTests {
    @Test("hover presentation contains no divider animation API")
    func noDividerHoverAnimation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let controller = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/awesoMux/Views/SidebarSplitController.swift"),
            encoding: .utf8
        )
        for forbidden in [
            "SidebarWidthAnimation", "AnimationRunner", "animateSidebarVisibility",
            "isHoverAnimating", "setSidebarVisible(",
        ] {
            #expect(!controller.contains(forbidden), "remove real-divider hover path: \(forbidden)")
        }
        let support = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/awesoMux/Views/SidebarSplitSupport.swift"),
            encoding: .utf8
        )
        #expect(!support.contains("setVisibility:"))
    }
}
