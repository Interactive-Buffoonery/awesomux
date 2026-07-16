import CoreGraphics
import AppKit
import AwesoMuxConfig
import Foundation
import SwiftUI
import Testing
@testable import AwesoMuxCore
@testable import awesoMux

@Suite("SidebarSplitController clamp", .serialized)
@MainActor
struct SidebarSplitControllerTests {
    private final class MonitorHarness {
        let token = NSObject()
        var addCount = 0
        var removeCount = 0
        var handler: ((NSEvent) -> NSEvent?)?

        func add(
            _ mask: NSEvent.EventTypeMask,
            _ handler: @escaping (NSEvent) -> NSEvent?
        ) -> Any? {
            #expect(mask == .mouseMoved)
            addCount += 1
            self.handler = handler
            return token
        }

        func remove(_ token: Any) {
            #expect(token as? NSObject === self.token)
            removeCount += 1
            handler = nil
        }
    }

    private final class FirstResponderView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private final class TextViewDelegateView: NSView, NSTextViewDelegate {
        override var acceptsFirstResponder: Bool { true }
    }

    private final class AccessibilityFocusView: NSView {
        var onFocusChange: ((Bool) -> Void)?
        private var focused = false

        override var acceptsFirstResponder: Bool { true }

        override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
            focused = accessibilityFocused
            onFocusChange?(accessibilityFocused)
        }

        override func isAccessibilityFocused() -> Bool { focused }
    }

    private final class EmptyWorkspaceReadinessWindow: NSWindow {
        var reportsKey = false
        var reportsOcclusion: NSWindow.OcclusionState = []

        override var isKeyWindow: Bool { reportsKey }
        override var occlusionState: NSWindow.OcclusionState { reportsOcclusion }
    }

    private func makeController(width: CGFloat = 1_200) -> (SidebarSplitController, NSViewController, NSViewController) {
        let sidebar = NSViewController()
        let detail = NSViewController()
        let controller = SidebarSplitController(
            sidebar: sidebar, detail: detail, applicationIsActive: { true })
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        return (controller, sidebar, detail)
    }

    private func hostInFixedWindow(_ controller: SidebarSplitController) -> NSWindow {
        controller.loadViewIfNeeded()
        let frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let window = NSWindow(contentRect: frame, styleMask: [], backing: .buffered, defer: false)
        let contentView = NSView(frame: frame)
        window.contentView = contentView
        controller.view.frame = contentView.bounds
        contentView.addSubview(controller.view)
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    private func hostInActiveWindow(
        _ controller: SidebarSplitController
    ) -> EmptyWorkspaceReadinessWindow {
        controller.loadViewIfNeeded()
        let frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let window = EmptyWorkspaceReadinessWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        let contentView = NSView(frame: frame)
        window.contentView = contentView
        controller.view.frame = contentView.bounds
        contentView.addSubview(controller.view)
        controller.view.layoutSubtreeIfNeeded()
        window.alphaValue = 0
        window.reportsKey = true
        window.orderFrontRegardless()
        return window
    }

    private func mouseMoved(in window: NSWindow, at location: CGPoint) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: .mouseMoved,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0
            ))
    }

    @Test("edge monitor synchronizes same-window moves without consuming events")
    func edgeMonitorSynchronizesOwningWindow() throws {
        let harness = MonitorHarness()
        let controller = SidebarSplitController(
            sidebar: NSViewController(),
            detail: NSViewController(),
            addLocalMouseMovedMonitor: { harness.add($0, $1) },
            removeLocalMouseMovedMonitor: { harness.remove($0) },
            applicationIsActive: { true })
        let window = hostInFixedWindow(controller)
        let otherWindow = NSWindow(
            contentRect: window.frame, styleMask: [], backing: .buffered, defer: false)
        controller.setEdgeTrackingEnabled(true)
        var reports: [(CGFloat, CGFloat)] = []
        var exits = 0
        controller.onEdgePointerMove = { reports.append(($0, $1)) }
        controller.onEdgeExit = { exits += 1 }
        let inside = try mouseMoved(in: window, at: CGPoint(x: 120, y: 100))
        let other = try mouseMoved(in: otherWindow, at: CGPoint(x: 120, y: 100))
        let outside = try mouseMoved(in: window, at: CGPoint(x: 900, y: 100))

        #expect(harness.handler?(inside) === inside)
        #expect(reports.count == 1)
        #expect(reports[0].0 == 120)
        #expect(reports[0].1 == 400)
        #expect(harness.handler?(other) === other)
        #expect(reports.count == 1)
        #expect(exits == 0)

        #expect(harness.handler?(outside) === outside)
        #expect(exits == 1)
        #expect(harness.handler?(outside) === outside)
        #expect(exits == 1)
    }

    @Test("one AppKit mouse-move pipeline publishes one edge update")
    func appKitMouseMovePipelinePublishesOnce() throws {
        let harness = MonitorHarness()
        let controller = SidebarSplitController(
            sidebar: NSViewController(),
            detail: NSViewController(),
            addLocalMouseMovedMonitor: { harness.add($0, $1) },
            removeLocalMouseMovedMonitor: { harness.remove($0) },
            applicationIsActive: { true })
        let window = hostInFixedWindow(controller)
        controller.setEdgeTrackingEnabled(true)
        defer { controller.setEdgeTrackingEnabled(false) }
        var reports: [(CGFloat, CGFloat)] = []
        controller.onEdgePointerMove = { reports.append(($0, $1)) }
        let event = try mouseMoved(in: window, at: CGPoint(x: 120, y: 100))
        controller.edgeTrackingViewForTesting.updateTrackingAreas()
        let trackingArea = try #require(
            controller.edgeTrackingViewForTesting.trackingAreas.first {
                $0.owner === controller.edgeTrackingViewForTesting
            })

        // A local monitor runs before normal AppKit dispatch. Returning the same
        // event lets any subscribed tracking-area handler receive it next.
        #expect(harness.handler?(event) === event)
        if trackingArea.options.contains(.mouseMoved) {
            controller.edgeTrackingViewForTesting.mouseMoved(with: event)
        }

        #expect(!trackingArea.options.contains(.mouseMoved))
        #expect(reports.count == 1)
        #expect(reports.first?.0 == 120)
        #expect(reports.first?.1 == 400)
    }

    @Test("native sidebar pointer resampling converts the current screen point on both sides")
    func nativeSidebarPointerResampling() throws {
        var currentScreenPoint = NSPoint.zero
        let sidebar = NSViewController()
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: NSViewController(),
            currentMouseLocation: { currentScreenPoint })
        let window = hostInFixedWindow(controller)
        controller.setSidebarWidth(300)

        for position in [AppearanceConfig.SidebarPosition.left, .right] {
            controller.setSidebarPosition(position)
            let insideWindow = sidebar.view.convert(
                NSPoint(x: sidebar.view.bounds.midX, y: sidebar.view.bounds.midY),
                to: nil)
            currentScreenPoint = window.convertPoint(toScreen: insideWindow)
            #expect(controller.resampleSidebarPointerForTesting() == true)

            currentScreenPoint = window.convertPoint(
                toScreen: NSPoint(x: controller.view.bounds.midX, y: -20))
            #expect(controller.resampleSidebarPointerForTesting() == false)
        }
    }

    @Test(
        "native tracking callbacks cannot republish after monitor exit",
        arguments: [
            (AppearanceConfig.SidebarPosition.left, CGFloat(120), CGFloat(900)),
            (.right, CGFloat(1_080), CGFloat(300)),
        ]
    )
    func nativeTrackingCallbacksStayExited(
        position: AppearanceConfig.SidebarPosition,
        insideX: CGFloat,
        outsideX: CGFloat
    ) throws {
        let harness = MonitorHarness()
        let controller = SidebarSplitController(
            sidebar: NSViewController(),
            detail: NSViewController(),
            addLocalMouseMovedMonitor: { harness.add($0, $1) },
            removeLocalMouseMovedMonitor: { harness.remove($0) },
            applicationIsActive: { true })
        let window = hostInFixedWindow(controller)
        controller.setSidebarPosition(position)
        controller.view.layoutSubtreeIfNeeded()
        controller.setEdgeTrackingEnabled(true)
        var reports = 0
        controller.onEdgePointerMove = { _, _ in reports += 1 }
        var exits = 0
        controller.onEdgeExit = { exits += 1 }
        let inside = try mouseMoved(in: window, at: CGPoint(x: insideX, y: 100))
        let outside = try mouseMoved(in: window, at: CGPoint(x: outsideX, y: 100))

        #expect(harness.handler?(inside) === inside)
        #expect(reports == 1)
        #expect(harness.handler?(outside) === outside)
        #expect(exits == 1)
        reports = 0

        controller.edgeTrackingViewForTesting.mouseEntered(with: outside)
        #expect(harness.handler?(outside) === outside)

        #expect(reports == 0)
        #expect(exits == 1)
    }

    @Test("edge monitor follows enabled attached lifecycle exactly once")
    func edgeMonitorLifecycle() throws {
        let harness = MonitorHarness()
        let controller = SidebarSplitController(
            sidebar: NSViewController(),
            detail: NSViewController(),
            addLocalMouseMovedMonitor: { harness.add($0, $1) },
            removeLocalMouseMovedMonitor: { harness.remove($0) })
        controller.setEdgeTrackingEnabled(true)
        #expect(harness.addCount == 0)

        let window = hostInFixedWindow(controller)
        let contentView = try #require(window.contentView)
        #expect(harness.addCount == 1)
        controller.setEdgeTrackingEnabled(true)
        #expect(harness.addCount == 1)

        controller.setEdgeTrackingEnabled(false)
        controller.setEdgeTrackingEnabled(false)
        #expect(harness.removeCount == 1)
        #expect(!window.acceptsMouseMovedEvents)

        controller.setEdgeTrackingEnabled(true)
        #expect(harness.addCount == 2)
        #expect(window.acceptsMouseMovedEvents)
        controller.view.removeFromSuperview()
        #expect(harness.removeCount == 2)
        #expect(!window.acceptsMouseMovedEvents)

        contentView.addSubview(controller.view)
        #expect(harness.addCount == 3)
        controller.finalizeOwnedLifecycle()
        controller.finalizeOwnedLifecycle()
        #expect(harness.removeCount == 3)
        #expect(!window.acceptsMouseMovedEvents)
    }

    @Test("edge monitor enables owning window mouse moves before installation")
    func edgeMonitorEnablesOwningWindowMouseMoves() throws {
        let frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let window = NSWindow(
            contentRect: frame, styleMask: [], backing: .buffered, defer: false)
        let harness = MonitorHarness()
        var acceptsMouseMovedEventsAtInstallation = false
        let controller = SidebarSplitController(
            sidebar: NSViewController(),
            detail: NSViewController(),
            addLocalMouseMovedMonitor: { mask, handler in
                acceptsMouseMovedEventsAtInstallation = window.acceptsMouseMovedEvents
                return harness.add(mask, handler)
            },
            removeLocalMouseMovedMonitor: { harness.remove($0) })
        controller.setEdgeTrackingEnabled(true)

        controller.loadViewIfNeeded()
        let contentView = try #require(window.contentView)
        controller.view.frame = contentView.bounds
        contentView.addSubview(controller.view)

        #expect(harness.addCount == 1)
        #expect(acceptsMouseMovedEventsAtInstallation)
        #expect(window.acceptsMouseMovedEvents)

        controller.finalizeOwnedLifecycle()
        #expect(!window.acceptsMouseMovedEvents)
    }

    @Test("edge monitor preserves a window that already accepted mouse moves")
    func edgeMonitorPreservesPriorEnabledState() {
        let harness = MonitorHarness()
        let controller = SidebarSplitController(
            sidebar: NSViewController(),
            detail: NSViewController(),
            addLocalMouseMovedMonitor: { harness.add($0, $1) },
            removeLocalMouseMovedMonitor: { harness.remove($0) })
        let window = hostInFixedWindow(controller)
        window.acceptsMouseMovedEvents = true

        controller.setEdgeTrackingEnabled(true)
        controller.setEdgeTrackingEnabled(false)

        #expect(window.acceptsMouseMovedEvents)
    }

    @Test("edge monitor follows a direct window rehost without reinstalling")
    func edgeMonitorFollowsDirectWindowRehost() throws {
        let harness = MonitorHarness()
        let controller = SidebarSplitController(
            sidebar: NSViewController(),
            detail: NSViewController(),
            addLocalMouseMovedMonitor: { harness.add($0, $1) },
            removeLocalMouseMovedMonitor: { harness.remove($0) },
            applicationIsActive: { true })
        let firstWindow = hostInFixedWindow(controller)
        controller.setEdgeTrackingEnabled(true)
        let secondWindow = NSWindow(
            contentRect: firstWindow.frame, styleMask: [], backing: .buffered, defer: false)
        secondWindow.acceptsMouseMovedEvents = false
        var reports: [(CGFloat, CGFloat)] = []
        controller.onEdgePointerMove = { reports.append(($0, $1)) }

        let addCountBeforeRehost = harness.addCount
        let removeCountBeforeRehost = harness.removeCount
        secondWindow.contentView = controller.view
        controller.viewWillAppear()

        #expect(harness.addCount == addCountBeforeRehost + 1)
        #expect(harness.removeCount == removeCountBeforeRehost + 1)
        #expect(!firstWindow.acceptsMouseMovedEvents)
        #expect(secondWindow.acceptsMouseMovedEvents)

        let firstWindowEvent = try mouseMoved(
            in: firstWindow, at: CGPoint(x: 120, y: 100))
        let secondWindowEvent = try mouseMoved(
            in: secondWindow, at: CGPoint(x: 120, y: 100))
        #expect(harness.handler?(firstWindowEvent) === firstWindowEvent)
        #expect(reports.isEmpty)
        #expect(harness.handler?(secondWindowEvent) === secondWindowEvent)
        #expect(reports.count == 1)
        #expect(reports[0].0 == 120)
        #expect(reports[0].1 == 400)

        controller.setEdgeTrackingEnabled(false)
        #expect(!secondWindow.acceptsMouseMovedEvents)
    }

    @Test("sidebar geometry mirrors across the pane extent")
    func mirroredGeometry() {
        let extent: CGFloat = 1_199
        #expect(SidebarSplitController.dividerCoordinate(forSidebarWidth: 300, paneExtent: extent, position: .left) == 300)
        #expect(SidebarSplitController.dividerCoordinate(forSidebarWidth: 300, paneExtent: extent, position: .right) == 899)
        #expect(SidebarSplitController.sidebarWidth(forDividerCoordinate: 300, paneExtent: extent, position: .left) == 300)
        #expect(SidebarSplitController.sidebarWidth(forDividerCoordinate: 899, paneExtent: extent, position: .right) == 300)
    }

    @Test("sidebar geometry stays finite for invalid pane extents")
    func invalidGeometry() {
        for extent in [CGFloat.zero, -10, .infinity, .nan] {
            let coordinate = SidebarSplitController.dividerCoordinate(forSidebarWidth: 300, paneExtent: extent, position: .right)
            let width = SidebarSplitController.sidebarWidth(forDividerCoordinate: 300, paneExtent: extent, position: .right)
            #expect(coordinate.isFinite)
            #expect(width.isFinite)
            #expect(coordinate >= 0)
            #expect(width >= 0)
        }
    }

    @Test("changing sides preserves semantic width and child identities")
    func changingSides() {
        let sidebar = NSViewController()
        let detail = NSViewController()
        let controller = SidebarSplitController(sidebar: sidebar, detail: detail)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        controller.setSidebarWidth(300)
        let sidebarView = sidebar.view
        let detailView = detail.view

        controller.setSidebarPosition(.right)

        #expect(sidebar.view === sidebarView)
        #expect(detail.view === detailView)
        #expect(controller.splitPaneViewsForTesting.first === detailView)
        #expect(abs(sidebarView.frame.width - 300) < 1)
    }

    @Test("edge tracker mirrors against live root width outside split panes")
    func edgeTrackerGeometry() {
        let (controller, sidebar, detail) = makeController()
        controller.setEdgeTrackingEnabled(true)

        #expect(controller.edgeTrackingFrameForTesting == CGRect(x: 0, y: 0, width: 400, height: 800))
        #expect(controller.splitPaneViewsForTesting.count == 2)
        #expect(
            controller.splitPaneViewsForTesting.contains {
                $0 === controller.sidebarPaneContainerForTesting
            })
        #expect(sidebar.view.superview === controller.sidebarPaneContainerForTesting)
        #expect(controller.splitPaneViewsForTesting.contains { $0 === detail.view })

        controller.setSidebarPosition(.right)
        controller.view.layoutSubtreeIfNeeded()

        #expect(controller.edgeTrackingFrameForTesting == CGRect(x: 800, y: 0, width: 400, height: 800))
        #expect(controller.splitPaneViewsForTesting.count == 2)
    }

    @Test("edge tracker geometry updates preserve detail first responder")
    func edgeTrackerPreservesFirstResponder() {
        let detail = NSViewController()
        let sentinel = FirstResponderView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        detail.view.addSubview(sentinel)
        let controller = SidebarSplitController(sidebar: NSViewController(), detail: detail)
        let window = hostInFixedWindow(controller)
        #expect(window.makeFirstResponder(sentinel))

        controller.setEdgeTrackingEnabled(true)
        controller.setSidebarPosition(.right)
        controller.view.frame.size.width = 900
        controller.view.layoutSubtreeIfNeeded()

        #expect(window.firstResponder === sentinel)
    }

    @Test("edge tracker republishes a stationary pointer after geometry changes")
    func edgeTrackerReclassifiesAfterResize() throws {
        let (controller, _, _) = makeController()
        let window = hostInFixedWindow(controller)
        controller.setEdgeTrackingEnabled(true)
        var reports: [(CGFloat, CGFloat)] = []
        controller.onEdgePointerMove = { reports.append(($0, $1)) }
        let event = try #require(
            NSEvent.mouseEvent(
                with: .mouseMoved,
                location: CGPoint(x: 200, y: 100),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0
            ))

        controller.edgeTrackingViewForTesting.synchronizePointer(
            locationInWindow: event.locationInWindow)
        controller.view.frame.size.width = 900
        controller.view.layoutSubtreeIfNeeded()

        #expect(reports.count == 2)
        #expect(reports[0].0 == 200)
        #expect(reports[0].1 == 400)
        #expect(reports[1].0 == 200)
        #expect(reports[1].1 == 300)
    }

    @Test("detaching invalidates the edge pointer sample before reattach and resize")
    func detachInvalidatesEdgePointerSample() {
        var currentScreenPoint = NSPoint.zero
        let controller = SidebarSplitController(
            sidebar: NSViewController(),
            detail: NSViewController(),
            currentMouseLocation: { currentScreenPoint },
            applicationIsActive: { true })
        let window = hostInFixedWindow(controller)
        controller.setEdgeTrackingEnabled(true)
        var reports: [(CGFloat, CGFloat)] = []
        var exits = 0
        controller.onEdgePointerMove = { reports.append(($0, $1)) }
        controller.onEdgeExit = { exits += 1 }
        controller.edgeTrackingViewForTesting.synchronizePointer(
            locationInWindow: CGPoint(x: 200, y: 100))
        #expect(reports.count == 1)

        controller.settleDetached()
        currentScreenPoint = window.convertPoint(
            toScreen: CGPoint(x: controller.view.bounds.midX, y: -20))
        controller.viewWillAppear()
        controller.view.frame.size.width = 900
        controller.view.layoutSubtreeIfNeeded()

        #expect(exits == 1)
        #expect(reports.count == 1)
    }

    @Test("disabling tracker hides it and exits once")
    func disablingEdgeTracker() {
        let (controller, _, _) = makeController()
        var exitCount = 0
        controller.onEdgeExit = { exitCount += 1 }
        controller.setEdgeTrackingEnabled(true)
        controller.edgeTrackingViewForTesting.synchronizePointer(
            locationInWindow: CGPoint(x: 12, y: 10))
        #expect(controller.isEdgeTrackingVisibleForTesting)

        controller.setEdgeTrackingEnabled(false)
        controller.setEdgeTrackingEnabled(false)

        #expect(!controller.isEdgeTrackingVisibleForTesting)
        #expect(exitCount == 1)
    }

    @Test("tracker availability loss is forwarded")
    func edgeTrackerAvailabilityLoss() {
        let (controller, _, _) = makeController()
        var lossCount = 0
        controller.onTrackingAvailabilityLost = { lossCount += 1 }

        controller.simulateTrackingAvailabilityLostForTesting()

        #expect(lossCount == 1)
    }

    @Test("changing sides preserves a child first responder")
    func changingSidesPreservesFirstResponder() {
        let sidebar = NSViewController()
        let sentinel = FirstResponderView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        sidebar.view.addSubview(sentinel)
        let controller = SidebarSplitController(sidebar: sidebar, detail: NSViewController())
        let window = NSWindow(contentViewController: controller)
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        controller.setSidebarWidth(300)
        #expect(window.makeFirstResponder(sentinel))

        controller.setSidebarPosition(.right)

        #expect(window.firstResponder === sentinel)
    }

    @Test("right sidebar uses semantic width for max and resize reclamp")
    func rightSideMaxAndReclamp() {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarPosition(.right)
        controller.setSidebarWidth(600)
        #expect(controller.maxSidebarWidth == 719)

        controller.view.frame.size.width = 720
        controller.view.layoutSubtreeIfNeeded()

        #expect(sidebar.view.frame.width == SidebarWidthPolicy.collapsedWidth)
    }

    @Test("hide suppresses callbacks and reveal restores width")
    func hideAndReveal() {
        let sidebar = NSViewController()
        let controller = SidebarSplitController(sidebar: sidebar, detail: NSViewController())
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        controller.setSidebarWidth(300)
        var live: [CGFloat] = []
        var commits: [CGFloat] = []
        controller.onLiveWidthChange = { live.append($0) }
        controller.onCommitWidth = { commits.append($0) }

        controller.setSidebarHidden(true)
        #expect(sidebar.view.frame.width == 0)
        #expect(live.isEmpty)
        #expect(commits.isEmpty)

        controller.setSidebarHidden(false)
        #expect(abs(sidebar.view.frame.width - 300) < 1)
    }

    @Test("persistent proxy hides and shows a live split on both sides")
    func persistentProxyHidesAndShowsBothSides() {
        for position in [AppearanceConfig.SidebarPosition.left, .right] {
            let (controller, sidebar, _) = makeController()
            let proxy = SidebarSplitProxy()
            controller.setSidebarPosition(position)
            controller.setSidebarWidth(300)
            controller.installCommandHandlers(on: proxy)

            #expect(proxy.setPersistentVisible?(false) == .applied)
            #expect(sidebar.view.frame.width == 0)

            #expect(proxy.setPersistentVisible?(true) == .applied)
            #expect(abs(sidebar.view.frame.width - 300) < 1)
        }
    }

    @Test("persistent show reveals a split hidden before runtime wiring")
    func persistentShowRevealsConstructedHiddenSplit() {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        let proxy = SidebarSplitProxy()
        controller.installCommandHandlers(on: proxy)

        #expect(proxy.setPersistentVisible?(true) == .applied)

        #expect(abs(sidebar.view.frame.width - 300) < 1)
    }

    @Test("finalized command host defers persistent visibility delivery")
    func finalizedCommandHostDefersPersistentVisibilityDelivery() {
        let (controller, _, _) = makeController()
        let proxy = SidebarSplitProxy()
        controller.installCommandHandlers(on: proxy)
        controller.finalizeOwnedLifecycle()

        #expect(proxy.setPersistentVisible?(false) == .deferredUntilHostReady)
        #expect(!controller.setPersistentSidebarVisible(false))
    }

    @Test("installing a laid-out command host publishes usable readiness once")
    func installingLaidOutCommandHostPublishesUsableReadinessOnce() {
        let (firstController, _, _) = makeController()
        let (secondController, _, _) = makeController()
        let proxy = SidebarSplitProxy()
        #expect(proxy.commandHostGeneration == 0)
        #expect(proxy.usableLayoutGeneration == 0)

        firstController.installCommandHandlers(on: proxy)
        #expect(proxy.commandHostGeneration == 1)
        #expect(proxy.usableLayoutGeneration == 1)

        firstController.view.layoutSubtreeIfNeeded()
        #expect(proxy.usableLayoutGeneration == 1)

        secondController.installCommandHandlers(on: proxy)
        #expect(proxy.commandHostGeneration == 2)
        #expect(proxy.usableLayoutGeneration == 2)
    }

    @Test("an installed command host publishes readiness only after usable layout")
    func commandHostWaitsForUsableLayout() {
        let controller = SidebarSplitController(
            sidebar: NSViewController(), detail: NSViewController())
        let proxy = SidebarSplitProxy()

        controller.installCommandHandlers(on: proxy)
        #expect(proxy.commandHostGeneration == 1)
        #expect(proxy.usableLayoutGeneration == 0)
        #expect(proxy.setPersistentVisible?(true) == .deferredUntilHostReady)

        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()

        #expect(proxy.usableLayoutGeneration == 1)
        #expect(proxy.setPersistentVisible?(true) == .applied)

        controller.view.layoutSubtreeIfNeeded()
        #expect(proxy.usableLayoutGeneration == 1)
    }

    @Test("a deallocated command host defers rather than rejecting")
    func deallocatedCommandHostDefers() {
        let proxy = SidebarSplitProxy()
        do {
            let controller = SidebarSplitController(
                sidebar: NSViewController(), detail: NSViewController())
            controller.installCommandHandlers(on: proxy)
        }

        #expect(proxy.setPersistentVisible?(false) == .deferredUntilHostReady)
    }

    @Test("persistent show defers when native geometry is unavailable")
    func persistentShowDefersForUnavailableGeometry() {
        let controller = SidebarSplitController(
            sidebar: NSViewController(), detail: NSViewController())
        #expect(controller.setPersistentSidebarVisible(false))

        #expect(
            controller.deliverPersistentSidebarVisible(true) == .deferredUntilHostReady)
        #expect(controller.hostModeForTesting == .hidden)
    }

    @Test("hiding hands sidebar focus off before applying hidden geometry")
    func hidingHandsSidebarFocusOff() {
        let sidebar = NSViewController()
        let sentinel = FirstResponderView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        sidebar.view.addSubview(sentinel)
        let detail = NSViewController()
        let destination = FirstResponderView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        detail.view.addSubview(destination)
        let controller = SidebarSplitController(
            sidebar: sidebar, detail: detail, applicationIsActive: { true })
        let window = hostInActiveWindow(controller)
        defer { window.orderOut(nil) }
        #expect(window.makeFirstResponder(sentinel))
        var handoffCount = 0
        var widthDuringHandoff: CGFloat?
        controller.onSidebarFocusHandoff = { request in
            handoffCount += 1
            #expect(!request.requiresAccessibilityFocus)
            widthDuringHandoff = sidebar.view.frame.width
            guard window.makeFirstResponder(destination) else { return nil }
            return SidebarFocusHandoffOutcome(
                destination: destination, satisfying: request)
        }

        controller.setSidebarHidden(true)

        #expect(handoffCount == 1)
        #expect((widthDuringHandoff ?? 0) > 0)
        #expect(sidebar.view.frame.width == 0)
        #expect(window.firstResponder === destination)
        #expect(window.firstResponder !== sentinel)
    }

    @Test(
        "empty workspace authoritative handoff leaves expanded search and collapsed action",
        arguments: ["expanded search", "collapsed action"])
    func emptyWorkspaceKeyboardFocusUsesAuthoritativeHandoff(_ source: String) {
        let sidebar = NSViewController()
        let sidebarFocus = FirstResponderView(
            frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        sidebarFocus.identifier = NSUserInterfaceItemIdentifier(source)
        sidebar.view.addSubview(sidebarFocus)
        let detail = NSViewController()
        let detailAction = FirstResponderView(
            frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        detail.view.addSubview(detailAction)
        sidebarFocus.nextKeyView = detailAction
        detailAction.nextKeyView = sidebarFocus
        let controller = SidebarSplitController(
            sidebar: sidebar, detail: detail, applicationIsActive: { true })
        let window = hostInActiveWindow(controller)
        defer { window.orderOut(nil) }
        #expect(window.makeFirstResponder(sidebarFocus))
        controller.onSidebarFocusHandoff = { request in
            #expect(!request.requiresAccessibilityFocus)
            guard window.makeFirstResponder(detailAction) else { return nil }
            return SidebarFocusHandoffOutcome(
                destination: detailAction, satisfying: request)
        }

        #expect(controller.setPersistentSidebarVisible(false))

        #expect(sidebar.view.frame.width == 0)
        #expect(window.firstResponder === detailAction)
    }

    @Test("empty workspace routes the expanded search field editor through its authoritative handoff")
    func emptyWorkspaceSearchFieldEditorUsesAuthoritativeHandoff() throws {
        let sidebar = NSViewController()
        let searchField = NSSearchField(
            frame: CGRect(x: 0, y: 0, width: 160, height: 24))
        sidebar.view.addSubview(searchField)
        let detail = NSViewController()
        let detailAction = FirstResponderView(
            frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        detail.view.addSubview(detailAction)
        searchField.nextKeyView = detailAction
        detailAction.nextKeyView = searchField
        let controller = SidebarSplitController(
            sidebar: sidebar, detail: detail, applicationIsActive: { true })
        let window = hostInActiveWindow(controller)
        defer { window.orderOut(nil) }
        searchField.selectText(nil)
        let fieldEditor = try #require(searchField.currentEditor() as? NSTextView)
        #expect(window.firstResponder === fieldEditor)
        #expect(searchField.nextValidKeyView === detailAction)
        #expect(detailAction.window === window)
        controller.onSidebarFocusHandoff = { request in
            #expect(!request.requiresAccessibilityFocus)
            guard window.makeFirstResponder(detailAction) else { return nil }
            return SidebarFocusHandoffOutcome(
                destination: detailAction, satisfying: request)
        }

        #expect(controller.setPersistentSidebarVisible(false))

        #expect(sidebar.view.frame.width == 0)
        #expect(window.firstResponder === detailAction)
    }

    @Test("direct sidebar text view uses the authoritative handoff without delegate substitution")
    func directSidebarTextViewUsesAuthoritativeHandoff() {
        let sidebar = NSViewController()
        let textView = NSTextView(
            frame: CGRect(x: 0, y: 0, width: 160, height: 80))
        let delegate = TextViewDelegateView(
            frame: CGRect(x: 0, y: 100, width: 20, height: 20))
        sidebar.view.addSubview(textView)
        sidebar.view.addSubview(delegate)
        textView.delegate = delegate
        let detail = NSViewController()
        let detailAction = FirstResponderView(
            frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        detail.view.addSubview(detailAction)
        textView.nextKeyView = detailAction
        delegate.nextKeyView = delegate
        detailAction.nextKeyView = textView
        let controller = SidebarSplitController(
            sidebar: sidebar, detail: detail, applicationIsActive: { true })
        let window = hostInActiveWindow(controller)
        defer { window.orderOut(nil) }
        #expect(!textView.isFieldEditor)
        #expect(window.makeFirstResponder(textView))
        controller.onSidebarFocusHandoff = { request in
            #expect(!request.requiresAccessibilityFocus)
            guard window.makeFirstResponder(detailAction) else { return nil }
            return SidebarFocusHandoffOutcome(
                destination: detailAction, satisfying: request)
        }

        #expect(controller.setPersistentSidebarVisible(false))

        #expect(sidebar.view.frame.width == 0)
        #expect(window.firstResponder === detailAction)
    }

    @Test("empty workspace moves keyboard and accessibility focus to detail content")
    func emptyWorkspaceCombinedFocusUsesNativeKeyViewLoop() {
        let sidebar = NSViewController()
        let sidebarFocus = AccessibilityFocusView(
            frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        sidebar.view.addSubview(sidebarFocus)
        let detail = NSViewController()
        let detailAction = AccessibilityFocusView(
            frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        detail.view.addSubview(detailAction)
        sidebarFocus.nextKeyView = detailAction
        detailAction.nextKeyView = sidebarFocus
        var focusedAccessibilityElement: Any?
        sidebarFocus.onFocusChange = { focused in
            if focused {
                focusedAccessibilityElement = sidebarFocus
            }
        }
        detailAction.onFocusChange = { focused in
            if focused {
                focusedAccessibilityElement = detailAction
            }
        }
        sidebarFocus.setAccessibilityFocused(true)
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: detail,
            interactionFocusedAccessibilityElement: { focusedAccessibilityElement },
            applicationIsActive: { true })
        let window = hostInActiveWindow(controller)
        defer { window.orderOut(nil) }
        #expect(window.makeFirstResponder(sidebarFocus))
        controller.onSidebarFocusHandoff = { request in
            #expect(request.requiresAccessibilityFocus)
            guard window.makeFirstResponder(detailAction) else { return nil }
            sidebarFocus.setAccessibilityFocused(false)
            detailAction.setAccessibilityFocused(true)
            guard detailAction.isAccessibilityFocused() else { return nil }
            return SidebarFocusHandoffOutcome(
                destination: detailAction, satisfying: request)
        }

        #expect(controller.setPersistentSidebarVisible(false))

        #expect(sidebar.view.frame.width == 0)
        #expect(window.firstResponder === detailAction)
        #expect(focusedAccessibilityElement as? NSView === detailAction)
    }

    @Test("real empty workspace action owns keyboard and accessibility handoff")
    func realEmptyWorkspaceActionOwnsCombinedFocusHandoff() async throws {
        let sidebar = NSViewController()
        let sidebarFocus = AccessibilityFocusView(
            frame: CGRect(x: 0, y: 0, width: 160, height: 24))
        sidebar.view.addSubview(sidebarFocus)
        var newWorkspaceCount = 0
        let detail = NSHostingController(
            rootView: EmptyWorkspaceView(
                mode: .firstLaunch,
                onNewWorkspace: { newWorkspaceCount += 1 },
                onOpenRecent: {},
                canReopenWorkspace: false))
        var focusedAccessibilityElement: Any?
        sidebarFocus.onFocusChange = { focused in
            focusedAccessibilityElement = focused ? sidebarFocus : nil
        }
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: detail,
            interactionFocusedAccessibilityElement: { focusedAccessibilityElement },
            applicationIsActive: { true })
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let window = EmptyWorkspaceReadinessWindow(
            contentRect: controller.view.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentViewController = controller
        window.reportsKey = true
        controller.view.layoutSubtreeIfNeeded()
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        detail.view.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        #expect(
            await waitUntil {
                window.layoutIfNeeded()
                detail.view.layoutSubtreeIfNeeded()
                window.recalculateKeyViewLoop()
                return EmptyWorkspaceAccessibilityFocusHandoff.target(in: window.contentView)
                    != nil
            })
        let target = try #require(
            EmptyWorkspaceAccessibilityFocusHandoff.target(in: window.contentView))
        let targetView = try #require(target as? NSView)
        #expect(target.accessibilityIdentifier() == EmptyWorkspaceAccessibilityFocusHandoff.targetIdentifier)
        #expect(target.accessibilityRole() == .button)
        #expect(target.accessibilityLabel() == "New Workspace")
        #expect(targetView.acceptsFirstResponder)
        #expect(targetView.canBecomeKeyView)
        #expect(sidebarFocus.nextValidKeyView === targetView)
        #expect(targetView.nextValidKeyView === sidebarFocus)
        #expect(target.accessibilityPerformPress())
        #expect(newWorkspaceCount == 1)
        #expect(
            !EmptyWorkspaceAccessibilityFocusHandoff.focus(
                SidebarFocusHandoffRequest(
                    requiresKeyboardFocus: true,
                    requiresAccessibilityFocus: false),
                in: window.contentView))
        target.setAccessibilityFocused(false)
        #expect(window.makeFirstResponder(sidebarFocus))
        sidebarFocus.setAccessibilityFocused(true)
        controller.onSidebarFocusHandoff = { request in
            #expect(request.requiresAccessibilityFocus)
            guard window.makeFirstResponder(targetView) else { return nil }
            sidebarFocus.setAccessibilityFocused(false)
            guard
                EmptyWorkspaceAccessibilityFocusHandoff.focus(
                    request, in: window.contentView)
            else { return nil }
            return SidebarFocusHandoffOutcome(
                destination: targetView, satisfying: request)
        }

        #expect(controller.setPersistentSidebarVisible(false))

        #expect(sidebar.view.frame.width == 0)
        #expect(window.firstResponder === targetView)
        #expect(target.isAccessibilityFocused())
    }

    @Test("empty workspace waits for active visible readiness and focuses only once")
    func emptyWorkspaceWaitsForActiveVisibleReadinessAndFocusesOnlyOnce() async throws {
        var applicationIsActive = false
        let initialFocusRequest = EmptyWorkspaceInitialAccessibilityFocusRequest(
            applicationIsActive: { applicationIsActive })
        let detail = NSHostingController(
            rootView: EmptyWorkspaceView(
                mode: .firstLaunch,
                onNewWorkspace: {},
                onOpenRecent: {},
                canReopenWorkspace: true,
                initialAccessibilityFocusRequest: initialFocusRequest))
        let window = EmptyWorkspaceReadinessWindow(
            contentRect: CGRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [],
            backing: .buffered,
            defer: false)
        let contentView = NSView(frame: CGRect(x: 0, y: 0, width: 720, height: 480))
        window.contentView = contentView
        detail.view.frame = contentView.bounds
        detail.view.autoresizingMask = [.width, .height]
        contentView.addSubview(detail.view)
        window.alphaValue = 0
        defer { window.orderOut(nil) }

        #expect(
            await waitUntil {
                window.layoutIfNeeded()
                detail.view.layoutSubtreeIfNeeded()
                return EmptyWorkspaceAccessibilityFocusHandoff.target(in: detail.view) != nil
            })
        let unsettledTarget = try #require(
            EmptyWorkspaceAccessibilityFocusHandoff.target(in: detail.view))
        #expect(!window.isVisible)
        #expect(!unsettledTarget.isAccessibilityFocused())
        #expect(!initialFocusRequest.isConsumed)

        window.orderFrontRegardless()
        await drainMainQueue()
        #expect(window.isVisible)
        #expect(!unsettledTarget.isAccessibilityFocused())
        #expect(!initialFocusRequest.isConsumed)

        window.reportsKey = true
        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: window)
        await drainMainQueue()
        #expect(!unsettledTarget.isAccessibilityFocused())
        #expect(!initialFocusRequest.isConsumed)

        applicationIsActive = true
        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp)
        await drainMainQueue()
        #expect(!unsettledTarget.isAccessibilityFocused())
        #expect(!initialFocusRequest.isConsumed)

        detail.view.frame.origin.x = contentView.bounds.maxX + 20
        window.reportsOcclusion = .visible
        NotificationCenter.default.post(
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window)
        await drainMainQueue()
        #expect(!unsettledTarget.isAccessibilityFocused())
        #expect(!initialFocusRequest.isConsumed)

        detail.view.frame = contentView.bounds
        NotificationCenter.default.post(
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window)
        #expect(
            await waitUntil {
                window.layoutIfNeeded()
                detail.view.layoutSubtreeIfNeeded()
                return EmptyWorkspaceAccessibilityFocusHandoff.target(in: detail.view)?
                    .isAccessibilityFocused() == true
            })
        let wideTarget = try #require(
            EmptyWorkspaceAccessibilityFocusHandoff.target(in: detail.view))
        #expect(wideTarget.isAccessibilityFocused())
        #expect(initialFocusRequest.isConsumed)

        // Replacing ViewThatFits' focused horizontal target with the vertical
        // target preserves VoiceOver focus across the layout reflow.
        window.setContentSize(CGSize(width: 300, height: 480))
        #expect(
            await waitUntil {
                window.layoutIfNeeded()
                detail.view.layoutSubtreeIfNeeded()
                guard
                    let narrowTarget = EmptyWorkspaceAccessibilityFocusHandoff.target(
                        in: detail.view)
                else { return false }
                return (narrowTarget as AnyObject) !== (wideTarget as AnyObject)
                    && narrowTarget.isAccessibilityFocused()
            })
        let narrowTarget = try #require(
            EmptyWorkspaceAccessibilityFocusHandoff.target(in: detail.view))
        #expect(narrowTarget.isAccessibilityFocused())

        // Once the user moves VoiceOver elsewhere, a later layout replacement
        // must not steal focus back.
        narrowTarget.setAccessibilityFocused(false)
        window.setContentSize(CGSize(width: 720, height: 480))
        #expect(
            await waitUntil {
                window.layoutIfNeeded()
                detail.view.layoutSubtreeIfNeeded()
                guard
                    let restoredTarget = EmptyWorkspaceAccessibilityFocusHandoff.target(
                        in: detail.view)
                else { return false }
                return (restoredTarget as AnyObject) !== (narrowTarget as AnyObject)
            })
        await drainMainQueue()
        #expect(
            EmptyWorkspaceAccessibilityFocusHandoff.target(in: detail.view)?
                .isAccessibilityFocused() == false)
        #expect(initialFocusRequest.isConsumed)
    }

    @Test("empty workspace accessibility press reports only live activation")
    func emptyWorkspaceAccessibilityPressReportsOnlyLiveActivation() {
        let target = EmptyWorkspacePrimaryActionFocusButton()
        var activationCount = 0
        target.onActivate = { activationCount += 1 }

        #expect(target.accessibilityPerformPress())
        #expect(activationCount == 1)

        target.isEnabled = false
        #expect(!target.accessibilityPerformPress())
        #expect(activationCount == 1)

        target.isEnabled = true
        target.dismantle()
        #expect(!target.accessibilityPerformPress())
        #expect(activationCount == 1)
    }

    @Test("dismantled empty workspace target stays retired when retained")
    func dismantledEmptyWorkspaceTargetStaysRetiredWhenRetained() {
        let target = EmptyWorkspacePrimaryActionFocusButton()
        var activationCount = 0
        target.onActivate = { activationCount += 1 }

        target.dismantle()
        target.setAccessibilityFocused(true)
        target.onActivate = { activationCount += 1 }

        #expect(!target.isAccessibilityFocused())
        #expect(!target.accessibilityPerformPress())
        #expect(activationCount == 0)
    }

    @Test("empty workspace target refuses accessibility focus in a non-key window")
    func emptyWorkspaceTargetRefusesBackgroundAccessibilityFocus() {
        let target = EmptyWorkspacePrimaryActionFocusButton()
        target.frame = CGRect(x: 20, y: 20, width: 160, height: 32)
        let window = EmptyWorkspaceReadinessWindow(
            contentRect: CGRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentView = target
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        #expect(window.isVisible)
        #expect(!window.isKeyWindow)

        target.setAccessibilityFocused(true)

        #expect(!target.isAccessibilityFocused())
    }

    @Test("empty workspace target dispatch reports only handled activation")
    func emptyWorkspaceTargetDispatchReportsOnlyHandledActivation() throws {
        let application = NSApplication.shared
        let target = EmptyWorkspacePrimaryActionFocusButton()
        var activationCount = 0
        target.onActivate = { activationCount += 1 }
        let action = try #require(target.action)
        let liveDispatcher = try #require(target.target as? NSResponder)
        try #require(liveDispatcher !== target)

        #expect(liveDispatcher.responds(to: action))
        #expect(application.sendAction(action, to: liveDispatcher, from: target))
        #expect(liveDispatcher.tryToPerform(action, with: nil))
        #expect(activationCount == 2)

        target.isEnabled = false
        #expect(target.action == nil)
        #expect(target.target == nil)
        #expect(!liveDispatcher.responds(to: action))
        #expect(!liveDispatcher.tryToPerform(action, with: nil))
        #expect(application.sendAction(action, to: liveDispatcher, from: target))
        #expect(activationCount == 2)
        // AppKit treats a nonnil explicit target as authoritative, not as an availability query.
        #expect(
            (application.target(forAction: action, to: liveDispatcher, from: target)
                as? NSResponder) === liveDispatcher)

        target.isEnabled = true
        #expect(target.action == action)
        let reenabledDispatcher = try #require(target.target as? NSResponder)
        #expect(reenabledDispatcher !== liveDispatcher)
        #expect(!liveDispatcher.responds(to: action))
        #expect(!liveDispatcher.tryToPerform(action, with: nil))
        #expect(reenabledDispatcher.responds(to: action))
        #expect(application.sendAction(action, to: reenabledDispatcher, from: target))
        #expect(activationCount == 3)

        target.onActivate = nil
        #expect(target.action == nil)
        #expect(target.target == nil)
        #expect(!liveDispatcher.responds(to: action))
        #expect(!liveDispatcher.tryToPerform(action, with: nil))
        #expect(!reenabledDispatcher.responds(to: action))
        #expect(!reenabledDispatcher.tryToPerform(action, with: nil))
        #expect(application.sendAction(action, to: reenabledDispatcher, from: target))
        #expect(activationCount == 3)

        target.onActivate = { activationCount += 1 }
        #expect(target.action == action)
        let restoredDispatcher = try #require(target.target as? NSResponder)
        #expect(restoredDispatcher !== liveDispatcher)
        #expect(restoredDispatcher !== reenabledDispatcher)
        #expect(!liveDispatcher.responds(to: action))
        #expect(!liveDispatcher.tryToPerform(action, with: nil))
        #expect(restoredDispatcher.responds(to: action))
        #expect(application.sendAction(action, to: restoredDispatcher, from: target))
        #expect(restoredDispatcher.tryToPerform(action, with: nil))
        #expect(activationCount == 5)

        target.dismantle()
        #expect(target.action == nil)
        #expect(target.target == nil)
        #expect(!liveDispatcher.responds(to: action))
        #expect(!liveDispatcher.tryToPerform(action, with: nil))
        #expect(!restoredDispatcher.responds(to: action))
        #expect(!restoredDispatcher.tryToPerform(action, with: nil))
        #expect(application.sendAction(action, to: restoredDispatcher, from: target))
        #expect(!target.accessibilityPerformPress())
        #expect(activationCount == 5)
    }

    @Test("empty workspace AppKit metadata uses localized visible copy")
    func emptyWorkspaceAppKitMetadataUsesLocalizedVisibleCopy() throws {
        let target = EmptyWorkspacePrimaryActionFocusButton()
        let label = String(
            localized: "New Workspace",
            comment: "Accessibility label for the empty workspace primary action.")
        let help = String(
            localized: "Create a new workspace",
            comment: "Accessibility help and tooltip for the empty workspace primary action.")

        #expect(target.accessibilityLabel() == label)
        #expect(target.accessibilityHelp() == help)
        #expect(target.toolTip == help)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/awesoMux/Views/SessionDetailView.swift"),
            encoding: .utf8)
        let targetSource = try #require(
            source.split(
                separator: "final class EmptyWorkspacePrimaryActionFocusButton",
                maxSplits: 1
            ).last?.split(separator: "private struct NeedsInputBar", maxSplits: 1).first)
        let compactTargetSource = targetSource.filter { !$0.isWhitespace }

        #expect(compactTargetSource.contains("String(localized:\"NewWorkspace\",comment:"))
        #expect(
            compactTargetSource.contains(
                "String(localized:\"Createanewworkspace\",comment:"))
        #expect(!targetSource.contains("defaultValue:"))
    }

    private func waitUntil(
        _ condition: () -> Bool,
        attempts: Int = 100
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    @Test("hiding leaves a detail first responder alone")
    func hidingLeavesDetailFocusAlone() {
        let sidebar = NSViewController()
        let detail = NSViewController()
        let sentinel = FirstResponderView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        detail.view.addSubview(sentinel)
        let controller = SidebarSplitController(sidebar: sidebar, detail: detail)
        let window = hostInFixedWindow(controller)
        #expect(window.makeFirstResponder(sentinel))
        var handoffCount = 0
        controller.onSidebarFocusHandoff = { _ in
            handoffCount += 1
            return nil
        }

        controller.setSidebarHidden(true)

        #expect(handoffCount == 0)
        #expect(sidebar.view.frame.width == 0)
        #expect(window.firstResponder === sentinel)
    }

    @Test("failed keyboard-only handoff leaves the visible sidebar responder intact")
    func failedKeyboardHandoffFailsClosed() {
        let sidebar = NSViewController()
        let sentinel = FirstResponderView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        sidebar.view.addSubview(sentinel)
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: NSViewController(),
            applicationIsActive: { true })
        let window = hostInActiveWindow(controller)
        defer { window.orderOut(nil) }
        #expect(window.makeFirstResponder(sentinel))
        controller.onSidebarFocusHandoff = { _ in nil }

        #expect(!controller.setPersistentSidebarVisible(false))

        #expect(sidebar.view.frame.width > 0)
        #expect(window.firstResponder === sentinel)
    }

    @Test("reported keyboard handoff success is rejected while focus remains in the sidebar")
    func unverifiedKeyboardHandoffFailsClosed() {
        let sidebar = NSViewController()
        let sentinel = FirstResponderView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        sidebar.view.addSubview(sentinel)
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: NSViewController(),
            applicationIsActive: { true })
        let window = hostInActiveWindow(controller)
        defer { window.orderOut(nil) }
        #expect(window.makeFirstResponder(sentinel))
        controller.hasActiveSidebarAccessibilityFocus = { true }
        controller.onSidebarFocusHandoff = { request in
            #expect(request.requiresAccessibilityFocus)
            return SidebarFocusHandoffOutcome(
                destination: sentinel, satisfying: request)
        }

        #expect(!controller.setPersistentSidebarVisible(false))

        #expect(sidebar.view.frame.width > 0)
        #expect(window.firstResponder === sentinel)
    }

    @Test("rejected combined handoff restores keyboard and accessibility focus to the sidebar")
    func rejectedCombinedHandoffRestoresPartiallyMovedFocus() {
        let sidebar = NSViewController()
        let detail = NSViewController()
        let originalFocus = AccessibilityFocusView(
            frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        let partialDestination = AccessibilityFocusView(
            frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        sidebar.view.addSubview(originalFocus)
        detail.view.addSubview(partialDestination)
        var focusedAccessibilityElement: Any?
        originalFocus.onFocusChange = { focused in
            if focused {
                focusedAccessibilityElement = originalFocus
            } else if focusedAccessibilityElement as? NSView === originalFocus {
                focusedAccessibilityElement = nil
            }
        }
        partialDestination.onFocusChange = { focused in
            if focused {
                focusedAccessibilityElement = partialDestination
            } else if focusedAccessibilityElement as? NSView === partialDestination {
                focusedAccessibilityElement = nil
            }
        }
        originalFocus.setAccessibilityFocused(true)
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: detail,
            interactionFocusedAccessibilityElement: { focusedAccessibilityElement },
            applicationIsActive: { true })
        let window = hostInActiveWindow(controller)
        defer { window.orderOut(nil) }
        #expect(window.makeFirstResponder(originalFocus))
        controller.onSidebarFocusHandoff = { request in
            #expect(request.requiresAccessibilityFocus)
            #expect(window.makeFirstResponder(partialDestination))
            originalFocus.setAccessibilityFocused(false)
            partialDestination.setAccessibilityFocused(true)
            return nil
        }

        #expect(!controller.setPersistentSidebarVisible(false))

        #expect(sidebar.view.frame.width > 0)
        #expect(window.firstResponder === originalFocus)
        #expect(focusedAccessibilityElement as? NSView === originalFocus)
        #expect(originalFocus.isAccessibilityFocused())
    }

    @Test("rejected handoff restores a direct sidebar text view, not its delegate")
    func rejectedHandoffRestoresDirectSidebarTextView() {
        let sidebar = NSViewController()
        let detail = NSViewController()
        let originalTextView = NSTextView(
            frame: CGRect(x: 0, y: 0, width: 160, height: 80))
        let textViewDelegate = TextViewDelegateView(
            frame: CGRect(x: 0, y: 100, width: 20, height: 20))
        let accessibilityFocus = AccessibilityFocusView(
            frame: CGRect(x: 0, y: 140, width: 20, height: 20))
        let partialDestination = AccessibilityFocusView(
            frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        sidebar.view.addSubview(originalTextView)
        sidebar.view.addSubview(textViewDelegate)
        sidebar.view.addSubview(accessibilityFocus)
        detail.view.addSubview(partialDestination)
        originalTextView.delegate = textViewDelegate
        var focusedAccessibilityElement: Any?
        accessibilityFocus.onFocusChange = { focused in
            focusedAccessibilityElement = focused ? accessibilityFocus : nil
        }
        partialDestination.onFocusChange = { focused in
            focusedAccessibilityElement = focused ? partialDestination : nil
        }
        accessibilityFocus.setAccessibilityFocused(true)
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: detail,
            interactionFocusedAccessibilityElement: { focusedAccessibilityElement },
            applicationIsActive: { true })
        let window = hostInActiveWindow(controller)
        defer { window.orderOut(nil) }
        #expect(!originalTextView.isFieldEditor)
        #expect(window.makeFirstResponder(originalTextView))
        controller.onSidebarFocusHandoff = { request in
            #expect(request.requiresAccessibilityFocus)
            #expect(window.makeFirstResponder(partialDestination))
            accessibilityFocus.setAccessibilityFocused(false)
            partialDestination.setAccessibilityFocused(true)
            return nil
        }

        #expect(!controller.setPersistentSidebarVisible(false))

        #expect(sidebar.view.frame.width > 0)
        #expect(window.firstResponder === originalTextView)
        #expect(focusedAccessibilityElement as? NSView === accessibilityFocus)
        #expect(accessibilityFocus.isAccessibilityFocused())
    }

    @Test("layout while hidden stays hidden without restoring expanded width")
    func hiddenResizeDoesNotRestore() {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)

        controller.view.frame.size.width = 1_600
        controller.view.layoutSubtreeIfNeeded()

        #expect(sidebar.view.frame.width == 0)
    }

    @Test("runtime-hidden split removes divider and gives detail the physical edge")
    func runtimeHiddenSplitHasNoDividerDeadStrip() {
        for position in [AppearanceConfig.SidebarPosition.left, .right] {
            let (controller, sidebar, detail) = makeController()
            controller.setSidebarPosition(position)
            controller.setSidebarWidth(300)
            let nativeDividerThickness = controller.dividerThicknessForTesting
            #expect(nativeDividerThickness > 0)

            #expect(controller.setPersistentSidebarVisible(false))
            controller.view.layoutSubtreeIfNeeded()

            #expect(controller.dividerThicknessForTesting == 0)
            #expect(sidebar.view.frame.width == 0)
            #expect(detail.view.frame == controller.splitViewForTesting.bounds)
            let hiddenEdgePoint = CGPoint(
                x: position == .left ? 0.5 : controller.splitViewForTesting.bounds.maxX - 0.5,
                y: controller.splitViewForTesting.bounds.midY)
            let hiddenEdgeHit = controller.splitViewForTesting.hitTest(hiddenEdgePoint)
            #expect(
                hiddenEdgeHit === detail.view
                    || hiddenEdgeHit?.isDescendant(of: detail.view) == true)

            controller.view.frame.size.width = 1_600
            controller.view.layoutSubtreeIfNeeded()

            #expect(controller.dividerThicknessForTesting == 0)
            #expect(detail.view.frame == controller.splitViewForTesting.bounds)

            controller.view.frame.size.width = 1_200
            controller.view.layoutSubtreeIfNeeded()
            controller.setSelectedSidebarWidth(720)
            #expect(controller.setPersistentSidebarVisible(true))

            #expect(controller.dividerThicknessForTesting == nativeDividerThickness)
            #expect(sidebar.view.frame.width == 719)
            #expect(detail.view.frame.width == 480)
        }
    }

    @Test("cold-hidden split removes divider on both sidebar sides")
    func coldHiddenSplitHasNoDividerDeadStrip() {
        for position in [AppearanceConfig.SidebarPosition.left, .right] {
            let sidebar = NSViewController()
            let detail = NSViewController()
            let controller = SidebarSplitController(sidebar: sidebar, detail: detail)
            controller.setSidebarPosition(position)
            controller.setSidebarHidden(true)
            controller.loadViewIfNeeded()
            controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
            controller.view.layoutSubtreeIfNeeded()

            #expect(controller.dividerThicknessForTesting == 0)
            #expect(sidebar.view.frame.width == 0)
            #expect(detail.view.frame == controller.splitViewForTesting.bounds)
            let hiddenEdgePoint = CGPoint(
                x: position == .left ? 0.5 : controller.splitViewForTesting.bounds.maxX - 0.5,
                y: controller.splitViewForTesting.bounds.midY)
            let hiddenEdgeHit = controller.splitViewForTesting.hitTest(hiddenEdgePoint)
            #expect(
                hiddenEdgeHit === detail.view
                    || hiddenEdgeHit?.isDescendant(of: detail.view) == true)
        }
    }

    @Test("hidden rail selection remains a deliberate rail after persistent reveal and grow")
    func hiddenRailSelectionDoesNotRestoreExpandedWidth() {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarWidth(300)
        #expect(controller.setPersistentSidebarVisible(false))
        controller.setSelectedSidebarWidth(SidebarWidthPolicy.collapsedWidth)

        #expect(controller.setPersistentSidebarVisible(true))
        #expect(sidebar.view.frame.width == SidebarWidthPolicy.collapsedWidth)

        controller.view.frame.size.width = 1_600
        controller.view.layoutSubtreeIfNeeded()

        #expect(sidebar.view.frame.width == SidebarWidthPolicy.collapsedWidth)
    }

    @Test("hidden expanded selection restores after a prior rail and narrow clamp")
    func hiddenExpandedSelectionRestoresAfterGrow() {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarWidth(SidebarWidthPolicy.collapsedWidth)
        #expect(controller.setPersistentSidebarVisible(false))
        controller.view.frame.size.width = 540
        controller.view.layoutSubtreeIfNeeded()
        controller.setSelectedSidebarWidth(420)

        #expect(controller.setPersistentSidebarVisible(true))
        #expect(sidebar.view.frame.width == SidebarWidthPolicy.collapsedWidth)

        controller.view.frame.size.width = 1_600
        controller.view.layoutSubtreeIfNeeded()

        #expect(sidebar.view.frame.width == 420)
    }

    @Test("persisted hidden state survives the first live window layout")
    func persistedHiddenColdLaunch() {
        for position in [AppearanceConfig.SidebarPosition.left, .right] {
            let sidebar = NSViewController()
            let controller = SidebarSplitController(sidebar: sidebar, detail: NSViewController())
            controller.setSidebarPosition(position)
            controller.setSidebarHidden(true)

            let window = NSWindow(contentViewController: controller)
            window.setContentSize(CGSize(width: 1_200, height: 800))
            window.makeKeyAndOrderFront(nil)
            controller.view.layoutSubtreeIfNeeded()

            #expect(window.isVisible)
            #expect(sidebar.view.frame.width == 0)
            window.orderOut(nil)
        }
    }

    @Test("hidden drag completion cannot commit zero width")
    func hiddenDragDoesNotCommit() {
        let (controller, _, _) = makeController()
        var commits: [CGFloat] = []
        controller.onCommitWidth = { commits.append($0) }
        controller.setSidebarHidden(true)

        controller.simulateDividerDragCompletionForTesting()

        #expect(commits.isEmpty)
    }

    @Test("setting width while hidden records reveal width without showing")
    func hiddenWidthRequest() {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)

        controller.setSidebarWidth(420)
        #expect(sidebar.view.frame.width == 0)
        #expect(controller.hostPresentationState.titlebarPresentationWidth == 420)
        #expect(controller.hostPresentationState.titlebarTranslationX == -420)
        controller.setSidebarHidden(false)

        #expect(abs(sidebar.view.frame.width - 420) < 1)
    }

    @Test("rail-zone widths snap while expanded widths are preserved")
    func preservesInRange() {
        #expect(
            SidebarSplitController.clampedWidth(187, maxWidth: 1000)
                == SidebarWidthPolicy.collapsedWidth
        )
        #expect(
            SidebarSplitController.clampedWidth(245, maxWidth: 1000)
                == SidebarWidthPolicy.collapsedWidth
        )
        #expect(SidebarSplitController.clampedWidth(287, maxWidth: 1000) == 287)
    }

    @Test("below-floor clamps up to the collapsed floor")
    func clampsFloor() {
        #expect(
            SidebarSplitController.clampedWidth(10, maxWidth: 1000)
                == SidebarWidthPolicy.collapsedWidth
        )
    }

    @Test("above the dynamic max clamps down to it")
    func clampsDynamicCeiling() {
        // The ceiling models windowWidth - terminalMinimum.
        #expect(SidebarSplitController.clampedWidth(900, maxWidth: 500) == 500)
    }

    @Test("non-finite falls back to the floor")
    func nonFiniteFallsBack() {
        #expect(
            SidebarSplitController.clampedWidth(.infinity, maxWidth: 1000)
                == SidebarWidthPolicy.collapsedWidth
        )
    }

    @Test("inverted range (max below floor, narrow window) still returns the floor")
    func invertedRangeReturnsFloor() {
        #expect(
            SidebarSplitController.clampedWidth(700, maxWidth: 40)
                == SidebarWidthPolicy.collapsedWidth
        )
    }

    @Test("restoring a wide stored width onto a narrow window snaps to the rail")
    func restoreWideWidthOntoNarrowWindow() {
        // Minimum window (720) with the 480 terminal floor leaves a 240 sidebar
        // max. A stored 600 (dragged on a wider window earlier) must snap to the
        // tight rail because the dynamic max sits in the no-wide-rail zone.
        let maxAtMinWindow = ContentView.minimumWindowWidth - ContentView.terminalMinimumWidth
        #expect(maxAtMinWindow == 240)
        #expect(
            SidebarSplitController.clampedWidth(600, maxWidth: maxAtMinWindow)
                == SidebarWidthPolicy.collapsedWidth
        )
    }

    @Test("all divider mutations route through the instrumented boundary")
    func dividerMutationBoundaryIsUnique() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL =
            testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/awesoMux/Views/SidebarSplitController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.components(separatedBy: "splitView.setPosition(").count - 1 == 1)
        let helper = try #require(source.range(of: "private func setDividerPosition"))
        #expect(source[helper.lowerBound...].contains("splitView.setPosition("))
    }
}

@Suite("SidebarSplitController reclamp action")
@MainActor
struct SidebarSplitControllerReclampTests {
    typealias Action = SidebarSplitController.ReclampAction

    // Sidebar sitting at the rail, window now has room, user didn't choose the rail.
    @Test("restore-on-grow fires when not dragging")
    func restoreWhenNotDragging() {
        #expect(
            SidebarSplitController.reclampAction(
                currentWidth: SidebarWidthPolicy.collapsedWidth,
                maxWidth: 1000,
                lastExpandedWidth: 296,
                userChoseRail: false,
                isDraggingDivider: false
            ) == .restoreExpanded(296)
        )
    }

    // The regression: dragging from expanded toward the rail must NOT spring back.
    @Test("restore-on-grow is suppressed during a divider drag")
    func noRestoreWhileDragging() {
        let action = SidebarSplitController.reclampAction(
            currentWidth: 120,  // below the rail threshold, mid-drag
            maxWidth: 1000,
            lastExpandedWidth: 296,
            userChoseRail: false,
            isDraggingDivider: true
        )
        // 120 is in the no-wide-rail dead zone, so the live clamp tightens it to the
        // rail — but it must NOT be a restore-to-expanded.
        #expect(action == .clamp(SidebarWidthPolicy.collapsedWidth))
        if case .restoreExpanded = action {
            Issue.record("restore-on-grow fired mid-drag — the #206 regression")
        }
    }

    // A window shrink concurrent with a drag must still pull the sidebar in so the
    // terminal can't be stranded below its minimum.
    @Test("terminal-starvation clamp still fires during a drag")
    func clampFiresWhileDragging() {
        // Wide sidebar, but the window shrank so maxWidth is now 240 (rail zone).
        #expect(
            SidebarSplitController.reclampAction(
                currentWidth: 600,
                maxWidth: 240,
                lastExpandedWidth: 600,
                userChoseRail: false,
                isDraggingDivider: true
            ) == .clamp(SidebarWidthPolicy.collapsedWidth)
        )
    }

    // A deliberate rail (⌘\ or drag-to-rail) must not auto-expand on a window grow.
    @Test("user-chosen rail is left alone on grow")
    func userChosenRailNotRestored() {
        #expect(
            SidebarSplitController.reclampAction(
                currentWidth: SidebarWidthPolicy.collapsedWidth,
                maxWidth: 1000,
                lastExpandedWidth: 296,
                userChoseRail: true,
                isDraggingDivider: false
            ) == .none
        )
    }

    // A settled expanded width that needs no correction is a no-op.
    @Test("settled width within bounds is a no-op")
    func settledWidthIsNoOp() {
        #expect(
            SidebarSplitController.reclampAction(
                currentWidth: 296,
                maxWidth: 1000,
                lastExpandedWidth: 296,
                userChoseRail: false,
                isDraggingDivider: false
            ) == .none
        )
    }
}
