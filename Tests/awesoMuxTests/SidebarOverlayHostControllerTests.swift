import AppKit
import AwesoMuxConfig
import Testing
@testable import awesoMux

@Suite("Sidebar overlay host", .serialized)
@MainActor
struct SidebarOverlayHostControllerTests {
    private func makeController(position: AppearanceConfig.SidebarPosition = .left) -> (
        SidebarSplitController, NSViewController, NSViewController
    ) {
        let sidebar = NSViewController()
        let detail = NSViewController()
        let controller = SidebarSplitController(sidebar: sidebar, detail: detail)
        controller.setSidebarPosition(position)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        return (controller, sidebar, detail)
    }

    @Test(
        "overlay reparents the one live sidebar host while split stays hidden", arguments: [AppearanceConfig.SidebarPosition.left, .right])
    func oneHostOverlay(position: AppearanceConfig.SidebarPosition) {
        let (controller, sidebar, detail) = makeController(position: position)
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        let detailFrame = detail.view.frame

        controller.setOverlayPresentedImmediately(true)

        #expect(controller.hostModeForTesting == .overlay(width: 300))
        #expect(sidebar.view.superview === controller.overlayContentViewForTesting)
        #expect(controller.sidebarHostOccurrenceCountForTesting == 1)
        #expect(controller.sidebarSplitPaneWidthForTesting == 0)
        #expect(detail.view.frame == detailFrame)
        #expect(
            controller.view.subviews.firstIndex(of: detail.view.superview!)! < controller.view.subviews.firstIndex(
                of: controller.overlayClipViewForTesting)!)
        if position == .left {
            #expect(controller.overlayClipViewForTesting.frame.minX == 0)
        } else {
            #expect(controller.overlayClipViewForTesting.frame.maxX == controller.view.bounds.maxX)
        }
    }

    @Test("dismissing overlay returns the same host to the hidden semantic pane")
    func dismissOverlay() {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        controller.setOverlayPresentedImmediately(true)

        controller.setOverlayPresentedImmediately(false)

        #expect(controller.hostModeForTesting == .hidden)
        #expect(sidebar.view.superview === controller.sidebarPaneContainerForTesting)
        #expect(controller.sidebarHostOccurrenceCountForTesting == 1)
        #expect(controller.overlayClipViewForTesting.isHidden)
    }
}
