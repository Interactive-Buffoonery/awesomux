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
            "SidebarWidthAnimation", "animateSidebarVisibility",
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

    @Test("persistent visibility is runtime-only and never driven by hover")
    func persistentVisibilityOwnership() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let content = try String(
            contentsOf: root.appendingPathComponent("Sources/awesoMux/Views/ContentView.swift"),
            encoding: .utf8
        )
        let settle = try #require(
            content.split(separator: "private func settleSidebarVisibilityExplicitly", maxSplits: 1)
                .last?.split(separator: "\n    }", maxSplits: 1).first
        )
        #expect(settle.contains("setPersistentVisible"))
        let proximity = try #require(
            content.split(separator: "SidebarProximityCue", maxSplits: 1).first
        )
        #expect(proximity.contains("onChange(of: sidebarPresentation.proximityState)"))
        #expect(proximity.contains("setOverlayVisible"))
    }
}
