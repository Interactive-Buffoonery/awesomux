import AppKit
import Foundation
import Testing
@testable import awesoMux

@Suite("Sidebar semantic pane identity", .serialized)
@MainActor
struct SidebarSemanticPaneIdentityTests {
    @Test("semantic split paths use the stable pane container")
    func sourceUsesStableContainer() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/awesoMux/Views/SidebarSplitController.swift"),
            encoding: .utf8
        )
        #expect(source.contains("private var sidebarPaneWidth: CGFloat {\n        sidebarPaneContainer.frame.width"))
        #expect(source.contains("view !== sidebarPaneContainer"))
        #expect(source.contains("splitView.addSubview(sidebarPaneContainer)"))
        #expect(source.contains("sidebar: sidebarPaneContainer"))
        #expect(!source.contains("splitView.addSubview(sidebarChild.view)"))
        #expect(!source.contains("sidebarChild.view.frame.width"))
        #expect(!source.contains("view !== sidebarChild.view"))
    }

    @Test("split panes remain stable across position and host modes")
    func stablePanes() {
        let detail = NSViewController()
        let controller = SidebarSplitController(sidebar: NSViewController(), detail: detail)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()

        #expect(controller.splitPaneViewsForTesting == [controller.sidebarPaneContainerForTesting, detail.view])
        controller.setSidebarPosition(.right)
        #expect(controller.splitPaneViewsForTesting == [detail.view, controller.sidebarPaneContainerForTesting])
        controller.setSidebarHidden(true)
        controller.setOverlayPresentedImmediately(true)
        #expect(controller.splitPaneViewsForTesting == [detail.view, controller.sidebarPaneContainerForTesting])
    }
}
