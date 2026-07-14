import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("Sidebar hover geometry isolation", .serialized)
@MainActor
struct SidebarHoverGeometryIsolationTests {
    private final class AnimationDriver {
        var presentationTranslation: CGFloat?
        var completions: [() -> Void] = []
    }

    private final class GeometryRecordingView: NSView {
        var changedSubmittedBackingSizes: [NSSize] = []

        override func setFrameSize(_ newSize: NSSize) {
            let previousSize = frame.size
            super.setFrameSize(newSize)
            guard newSize != previousSize else { return }
            changedSubmittedBackingSizes.append(convertToBacking(NSRect(origin: .zero, size: newSize)).size)
        }
    }

    private func makeHiddenController(
        position: AppearanceConfig.SidebarPosition,
        width: CGFloat,
        driver: AnimationDriver = AnimationDriver()
    ) -> (SidebarSplitController, GeometryRecordingView, AnimationDriver) {
        let sidebar = NSViewController()
        let detail = NSViewController()
        let recordingView = GeometryRecordingView()
        detail.view = recordingView
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: detail,
            overlayPresentationTranslation: { driver.presentationTranslation },
            overlayAnimationRunner: { _, _, _, _, completion in
                driver.completions.append(completion)
            })
        controller.setSidebarPosition(position)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        controller.setSidebarWidth(width)
        controller.setPersistentSidebarVisible(false)
        recordingView.changedSubmittedBackingSizes.removeAll()
        controller.resetGeometryInstrumentationForTesting()
        return (controller, recordingView, driver)
    }

    @Test(
        "reveal and hide never submit split or backing geometry",
        arguments: [
            (AppearanceConfig.SidebarPosition.left, SidebarWidthPolicy.collapsedWidth, false),
            (.left, SidebarWidthPolicy.expandedWidth, false),
            (.right, SidebarWidthPolicy.collapsedWidth, false),
            (.right, SidebarWidthPolicy.expandedWidth, false),
            (.left, SidebarWidthPolicy.collapsedWidth, true),
            (.left, SidebarWidthPolicy.expandedWidth, true),
            (.right, SidebarWidthPolicy.collapsedWidth, true),
            (.right, SidebarWidthPolicy.expandedWidth, true),
        ]
    )
    func revealAndHide(
        position: AppearanceConfig.SidebarPosition,
        width: CGFloat,
        reduceMotion: Bool
    ) {
        let (controller, detail, driver) = makeHiddenController(position: position, width: width)
        let detailFrame = detail.frame

        controller.setOverlayPresented(true, transition: .hover, reduceMotion: reduceMotion)
        driver.completions.last?()
        controller.setOverlayPresented(false, transition: .hover, reduceMotion: reduceMotion)
        driver.completions.last?()

        #expect(controller.splitPositionMutationIntentCountForTesting == 0)
        #expect(detail.changedSubmittedBackingSizes.isEmpty)
        #expect(detail.frame == detailFrame)
    }

    @Test("rapid reversal and partial-animation width remap preserve detail geometry")
    func reversalAndWidthRemap() {
        for position in [AppearanceConfig.SidebarPosition.left, .right] {
            let (controller, detail, driver) = makeHiddenController(position: position, width: 300)
            let detailFrame = detail.frame

            controller.setOverlayPresented(true, transition: .hover, reduceMotion: false)
            let staleReveal = driver.completions.last
            driver.presentationTranslation = position == .left ? -150 : 150
            controller.setOverlayPresented(false, transition: .hover, reduceMotion: false)
            controller.setOverlayPresented(true, transition: .hover, reduceMotion: false)
            controller.setSelectedSidebarWidth(SidebarWidthPolicy.collapsedWidth)
            staleReveal?()
            driver.completions.last?()

            #expect(controller.splitPositionMutationIntentCountForTesting == 0)
            #expect(detail.changedSubmittedBackingSizes.isEmpty)
            #expect(detail.frame == detailFrame)
        }
    }

    @Test("window resize reclamps only the overlay while the split stays hidden")
    func hiddenWindowResize() {
        for position in [AppearanceConfig.SidebarPosition.left, .right] {
            let (controller, detail, _) = makeHiddenController(position: position, width: 600)

            controller.setOverlayPresentedImmediately(true)
            controller.view.frame.size.width = 900
            controller.view.layoutSubtreeIfNeeded()
            detail.changedSubmittedBackingSizes.removeAll()
            controller.resetGeometryInstrumentationForTesting()
            controller.setSelectedSidebarWidth(SidebarWidthPolicy.expandedWidth)

            #expect(controller.splitPositionMutationIntentCountForTesting == 0)
            #expect(detail.changedSubmittedBackingSizes.isEmpty)
        }
    }

    @Test("hidden rail and full selection never changes backing geometry")
    func hiddenWidthSelection() {
        let (controller, detail, _) = makeHiddenController(position: .left, width: 300)
        let detailFrame = detail.frame

        controller.setSelectedSidebarWidth(SidebarWidthPolicy.collapsedWidth)
        controller.setSelectedSidebarWidth(SidebarWidthPolicy.expandedWidth)

        #expect(controller.splitPositionMutationIntentCountForTesting == 0)
        #expect(detail.changedSubmittedBackingSizes.isEmpty)
        #expect(detail.frame == detailFrame)
    }

    @Test("explicit persistent show submits exactly one final geometry mutation")
    func persistentShowPositiveControl() {
        for position in [AppearanceConfig.SidebarPosition.left, .right] {
            let (controller, detail, _) = makeHiddenController(position: position, width: 300)

            controller.setOverlayPresentedImmediately(true)
            controller.setPersistentSidebarVisible(true)

            #expect(controller.splitPositionMutationIntentCountForTesting == 1)
            #expect(detail.changedSubmittedBackingSizes.count == 1)
            #expect(
                detail.changedSubmittedBackingSizes.last
                    == detail.convertToBacking(NSRect(origin: .zero, size: detail.frame.size)).size)
        }
    }
}
