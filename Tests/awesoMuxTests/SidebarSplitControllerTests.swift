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
        var handler: ((NSEvent) -> NSEvent?)?

        func add(
            _ mask: NSEvent.EventTypeMask,
            _ handler: @escaping (NSEvent) -> NSEvent?
        ) -> Any? {
            #expect(mask == .mouseMoved)
            self.handler = handler
            return token
        }

        func remove(_ token: Any) {
            #expect(token as? NSObject === self.token)
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

    @Test(arguments: [
        (AppearanceConfig.SidebarPosition.left, CGFloat(120), CGFloat(900)),
        (.right, CGFloat(1_080), CGFloat(300)),
    ])
    func edgeMonitor(position: AppearanceConfig.SidebarPosition, insideX: CGFloat, outsideX: CGFloat) throws {
        let harness = MonitorHarness()
        let controller = SidebarSplitController(
            sidebar: NSViewController(), detail: NSViewController(),
            addLocalMouseMovedMonitor: { harness.add($0, $1) }, removeLocalMouseMovedMonitor: { harness.remove($0) },
            applicationIsActive: { true })
        let window = hostInFixedWindow(controller)
        let otherWindow = NSWindow(contentRect: window.frame, styleMask: [], backing: .buffered, defer: false)
        controller.setSidebarPosition(position)
        controller.view.layoutSubtreeIfNeeded()
        controller.setEdgeTrackingEnabled(true)
        defer { controller.setEdgeTrackingEnabled(false) }
        var reports: [(CGFloat, CGFloat)] = []
        var exits = 0
        controller.onEdgePointerMove = { reports.append(($0, $1)) }
        controller.onEdgeExit = { exits += 1 }
        let inside = try mouseMoved(in: window, at: CGPoint(x: insideX, y: 100))
        let other = try mouseMoved(in: otherWindow, at: CGPoint(x: insideX, y: 100))
        let outside = try mouseMoved(in: window, at: CGPoint(x: outsideX, y: 100))
        #expect(harness.handler?(inside) === inside)
        #expect(reports.count == 1)
        #expect(reports[0].0 == insideX - (position == .right ? 800 : 0))
        #expect(reports[0].1 == 400)
        #expect(harness.handler?(other) === other)
        #expect(reports.count == 1)
        #expect(exits == 0)
        #expect(harness.handler?(outside) === outside)
        #expect(exits == 1)
        #expect(harness.handler?(outside) === outside)
        #expect(exits == 1)
        reports.removeAll()
        controller.edgeTrackingViewForTesting.mouseEntered(with: outside)
        #expect(harness.handler?(outside) === outside)
        #expect(reports.isEmpty)
        #expect(exits == 1)
    }

    @Test(arguments: [false, true])
    func changingSidebarSides(preserveFocus: Bool) {
        let (controller, sidebar, detail) = makeController()
        let sentinel = FirstResponderView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        sidebar.view.addSubview(sentinel)
        let window = hostInFixedWindow(controller)
        controller.setSidebarWidth(300)
        let sidebarView = sidebar.view
        let detailView = detail.view
        if preserveFocus { #expect(window.makeFirstResponder(sentinel)) }
        controller.setSidebarPosition(.right)
        #expect(sidebar.view === sidebarView)
        #expect(detail.view === detailView)
        #expect(controller.splitPaneViewsForTesting.first === detailView)
        #expect(abs(sidebarView.frame.width - 300) < 1)
        if preserveFocus { #expect(window.firstResponder === sentinel) }
    }

    @Test(arguments: ["direct", "proxy left", "proxy right", "constructed hidden", "resize", "cold left", "cold right", "drag", "width"])
    func visibilityLifecycle(scenario: String) {
        let sidebar = NSViewController()
        let controller = SidebarSplitController(sidebar: sidebar, detail: NSViewController())
        controller.setSidebarPosition(scenario.hasSuffix("right") ? .right : .left)
        let cold = scenario.hasPrefix("cold")
        if cold { controller.setSidebarHidden(true) }
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        if !cold { controller.setSidebarWidth(300) }
        var live: [CGFloat] = []
        var commits: [CGFloat] = []
        controller.onLiveWidthChange = { live.append($0) }
        controller.onCommitWidth = { commits.append($0) }
        let proxy = SidebarSplitProxy()
        if scenario.hasPrefix("proxy") { controller.installCommandHandlers(on: proxy) }
        if cold {
            let window = NSWindow(contentViewController: controller)
            window.setContentSize(CGSize(width: 1_200, height: 800))
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            controller.view.layoutSubtreeIfNeeded()
            #expect(window.isVisible)
            #expect(sidebar.view.frame.width == 0)
            return
        }
        if scenario.hasPrefix("proxy") {
            #expect(proxy.setPersistentVisible?(false) == .applied)
        } else {
            controller.setSidebarHidden(true)
        }
        #expect(sidebar.view.frame.width == 0)
        #expect(live.isEmpty)
        #expect(commits.isEmpty)
        if scenario == "resize" {
            controller.view.frame.size.width = 1_600
            controller.view.layoutSubtreeIfNeeded()
            #expect(sidebar.view.frame.width == 0)
            return
        }
        if scenario == "drag" {
            controller.simulateDividerDragCompletionForTesting()
            #expect(commits.isEmpty)
            return
        }
        if scenario == "width" {
            controller.setSidebarWidth(420)
            #expect(sidebar.view.frame.width == 0)
        }
        if scenario == "constructed hidden" { controller.installCommandHandlers(on: proxy) }
        if scenario.hasPrefix("proxy") || scenario == "constructed hidden" {
            #expect(proxy.setPersistentVisible?(true) == .applied)
        } else {
            controller.setSidebarHidden(false)
        }
        #expect(abs(sidebar.view.frame.width - (scenario == "width" ? 420 : 300)) < 1)
    }

    @Test(arguments: ["finalized", "layout", "deallocated", "geometry"])
    func deferredCommands(scenario: String) {
        let proxy = SidebarSplitProxy()
        if scenario == "deallocated" {
            do {
                let controller = SidebarSplitController(sidebar: NSViewController(), detail: NSViewController())
                controller.installCommandHandlers(on: proxy)
            }
            #expect(proxy.setPersistentVisible?(false) == .deferredUntilHostReady)
            return
        }
        let controller =
            scenario == "finalized"
            ? makeController().0
            : SidebarSplitController(sidebar: NSViewController(), detail: NSViewController())
        if scenario == "geometry" {
            #expect(controller.setPersistentSidebarVisible(false))
            #expect(controller.deliverPersistentSidebarVisible(true) == .deferredUntilHostReady)
            #expect(controller.hostModeForTesting == .hidden)
            return
        }
        controller.installCommandHandlers(on: proxy)
        if scenario == "finalized" {
            controller.finalizeOwnedLifecycle()
            #expect(proxy.setPersistentVisible?(false) == .deferredUntilHostReady)
            #expect(!controller.setPersistentSidebarVisible(false))
        } else {
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
    }

    @Test(arguments: ["keyboard", "expanded search", "collapsed action", "field editor", "text view", "combined", "detail"])
    func focusHandoffOnHide(source: String) throws {
        let sidebar = NSViewController()
        let detail = NSViewController()
        let ordinary = AccessibilityFocusView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        ordinary.identifier = NSUserInterfaceItemIdentifier(source)
        let search = NSSearchField(frame: CGRect(x: 0, y: 0, width: 160, height: 24))
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 160, height: 80))
        let delegate = TextViewDelegateView(frame: CGRect(x: 0, y: 100, width: 20, height: 20))
        text.delegate = delegate
        let sourceView: NSView = source == "field editor" ? search : (source == "text view" ? text : ordinary)
        sidebar.view.addSubview(sourceView)
        if source == "text view" { sidebar.view.addSubview(delegate); delegate.nextKeyView = delegate }
        let destination = AccessibilityFocusView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        detail.view.addSubview(destination)
        sourceView.nextKeyView = destination
        destination.nextKeyView = sourceView
        var focused: Any?
        ordinary.onFocusChange = { if $0 { focused = ordinary } }
        destination.onFocusChange = { if $0 { focused = destination } }
        if source == "combined" { ordinary.setAccessibilityFocused(true) }
        let controller = SidebarSplitController(
            sidebar: sidebar, detail: detail,
            interactionFocusedAccessibilityElement: { focused }, applicationIsActive: { true })
        let window = hostInActiveWindow(controller)
        defer { window.orderOut(nil) }
        let original: NSView
        if source == "field editor" {
            search.selectText(nil)
            original = try #require(search.currentEditor() as? NSTextView)
            #expect(search.nextValidKeyView === destination)
        } else {
            original = source == "detail" ? destination : sourceView
            #expect(window.makeFirstResponder(original))
            if source == "text view" { #expect(!text.isFieldEditor) }
        }
        #expect(window.firstResponder === original)
        var handoffs = 0
        var widthDuringHandoff: CGFloat = 0
        controller.onSidebarFocusHandoff = { request in
            handoffs += 1
            widthDuringHandoff = sidebar.view.frame.width
            #expect(request.requiresAccessibilityFocus == (source == "combined"))
            guard window.makeFirstResponder(destination) else { return nil }
            if source == "combined" {
                ordinary.setAccessibilityFocused(false)
                destination.setAccessibilityFocused(true)
                guard destination.isAccessibilityFocused() else { return nil }
            }
            return SidebarFocusHandoffOutcome(destination: destination, satisfying: request)
        }
        #expect(controller.setPersistentSidebarVisible(false))
        #expect(sidebar.view.frame.width == 0)
        #expect(window.firstResponder === destination)
        #expect(handoffs == (source == "detail" ? 0 : 1))
        if source != "detail" { #expect(widthDuringHandoff > 0) }
        if source == "combined" { #expect(focused as? NSView === destination) }
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
                newWorkspace: KeyboardShortcutCatalog.newWorkspace,
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

        window.layoutIfNeeded()
        detail.view.layoutSubtreeIfNeeded()
        await drainMainQueue()
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
        window.layoutIfNeeded()
        detail.view.layoutSubtreeIfNeeded()
        await drainMainQueue()
        let wideTarget = try #require(
            EmptyWorkspaceAccessibilityFocusHandoff.target(in: detail.view))
        #expect(wideTarget.isAccessibilityFocused())
        #expect(initialFocusRequest.isConsumed)

        // Replacing ViewThatFits' focused horizontal target with the vertical
        // target preserves VoiceOver focus across the layout reflow.
        window.setContentSize(CGSize(width: 300, height: 480))
        window.layoutIfNeeded()
        detail.view.layoutSubtreeIfNeeded()
        await drainMainQueue()
        let narrowTarget = try #require(
            EmptyWorkspaceAccessibilityFocusHandoff.target(in: detail.view))
        let replacedWideTarget = (narrowTarget as AnyObject) !== (wideTarget as AnyObject)
        #expect(replacedWideTarget)
        #expect(narrowTarget.isAccessibilityFocused())

        // Once the user moves VoiceOver elsewhere, a later layout replacement
        // must not steal focus back.
        narrowTarget.setAccessibilityFocused(false)
        window.setContentSize(CGSize(width: 720, height: 480))
        window.layoutIfNeeded()
        detail.view.layoutSubtreeIfNeeded()
        await drainMainQueue()
        let restoredTarget = try #require(EmptyWorkspaceAccessibilityFocusHandoff.target(in: detail.view))
        let replacedNarrowTarget = (restoredTarget as AnyObject) !== (narrowTarget as AnyObject)
        #expect(replacedNarrowTarget)
        await drainMainQueue()
        #expect(
            EmptyWorkspaceAccessibilityFocusHandoff.target(in: detail.view)?
                .isAccessibilityFocused() == false)
        #expect(initialFocusRequest.isConsumed)
    }

    @Test(arguments: [false, true])
    func primaryActionButton(retiredFirst: Bool) {
        let target = EmptyWorkspacePrimaryActionFocusButton()
        var activations = 0
        target.onActivate = { activations += 1 }
        if retiredFirst {
            target.dismantle()
            target.setAccessibilityFocused(true)
            target.onActivate = { activations += 1 }
            #expect(!target.isAccessibilityFocused())
            #expect(!target.accessibilityPerformPress())
            #expect(activations == 0)
        } else {
            #expect(target.accessibilityPerformPress())
            #expect(activations == 1)
            target.isEnabled = false
            #expect(!target.accessibilityPerformPress())
            #expect(activations == 1)
            target.isEnabled = true
            target.dismantle()
            #expect(!target.accessibilityPerformPress())
            #expect(activations == 1)
        }
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

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    @Test(arguments: ["failed", "unverified", "partial", "text view"])
    func rejectedHandoffRestoresFocus(scenario: String) {
        let sidebar = NSViewController()
        let detail = NSViewController()
        let originalAX = AccessibilityFocusView(frame: CGRect(x: 0, y: 140, width: 20, height: 20))
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 160, height: 80))
        let delegate = TextViewDelegateView(frame: CGRect(x: 0, y: 100, width: 20, height: 20))
        let destination = AccessibilityFocusView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        sidebar.view.addSubview(originalAX)
        detail.view.addSubview(destination)
        let original: NSView = scenario == "text view" ? text : originalAX
        if scenario == "text view" {
            text.delegate = delegate
            sidebar.view.addSubview(text)
            sidebar.view.addSubview(delegate)
            #expect(!text.isFieldEditor)
        }
        var focused: Any?
        originalAX.onFocusChange = { focused = $0 ? originalAX : nil }
        destination.onFocusChange = { focused = $0 ? destination : nil }
        let partial = ["partial", "text view"].contains(scenario)
        if partial { originalAX.setAccessibilityFocused(true) }
        let controller = SidebarSplitController(
            sidebar: sidebar, detail: detail,
            interactionFocusedAccessibilityElement: { focused }, applicationIsActive: { true })
        let window = hostInActiveWindow(controller)
        defer { window.orderOut(nil) }
        #expect(window.makeFirstResponder(original))
        if scenario == "unverified" { controller.hasActiveSidebarAccessibilityFocus = { true } }
        controller.onSidebarFocusHandoff = { request in
            #expect(request.requiresAccessibilityFocus == (partial || scenario == "unverified"))
            if scenario == "unverified" {
                return SidebarFocusHandoffOutcome(destination: original, satisfying: request)
            }
            if partial {
                #expect(window.makeFirstResponder(destination))
                originalAX.setAccessibilityFocused(false)
                destination.setAccessibilityFocused(true)
            }
            return nil
        }
        #expect(!controller.setPersistentSidebarVisible(false))
        #expect(sidebar.view.frame.width > 0)
        #expect(window.firstResponder === original)
        if partial {
            #expect(focused as? NSView === originalAX)
            #expect(originalAX.isAccessibilityFocused())
        }
    }

    @Test(arguments: [AppearanceConfig.SidebarPosition.left, .right], [false, true])
    func dividerDeadStrip(position: AppearanceConfig.SidebarPosition, cold: Bool) {
        let sidebar = NSViewController()
        let detail = NSViewController()
        let controller = SidebarSplitController(sidebar: sidebar, detail: detail)
        controller.setSidebarPosition(position)
        if cold { controller.setSidebarHidden(true) }
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let thickness = controller.dividerThicknessForTesting
        if !cold {
            controller.setSidebarWidth(300)
            #expect(thickness > 0)
            #expect(controller.setPersistentSidebarVisible(false))
            controller.view.layoutSubtreeIfNeeded()
        }
        #expect(controller.dividerThicknessForTesting == 0)
        #expect(sidebar.view.frame.width == 0)
        #expect(detail.view.frame == controller.splitViewForTesting.bounds)
        let point = CGPoint(
            x: position == .left ? 0.5 : controller.splitViewForTesting.bounds.maxX - 0.5,
            y: controller.splitViewForTesting.bounds.midY)
        let hit = controller.splitViewForTesting.hitTest(point)
        #expect(hit === detail.view || hit?.isDescendant(of: detail.view) == true)
        if !cold {
            controller.view.frame.size.width = 1_600
            controller.view.layoutSubtreeIfNeeded()
            #expect(controller.dividerThicknessForTesting == 0)
            #expect(detail.view.frame == controller.splitViewForTesting.bounds)
            controller.view.frame.size.width = 1_200
            controller.view.layoutSubtreeIfNeeded()
            controller.setSelectedSidebarWidth(720)
            #expect(controller.setPersistentSidebarVisible(true))
            #expect(controller.dividerThicknessForTesting == thickness)
            #expect(sidebar.view.frame.width == 719)
            #expect(detail.view.frame.width == 480)
        }
    }

    @Test(arguments: [false, true])
    func hiddenWidthSelection(expanded: Bool) {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarWidth(expanded ? SidebarWidthPolicy.collapsedWidth : 300)
        #expect(controller.setPersistentSidebarVisible(false))
        if expanded {
            controller.view.frame.size.width = 540
            controller.view.layoutSubtreeIfNeeded()
        }
        controller.setSelectedSidebarWidth(expanded ? 420 : SidebarWidthPolicy.collapsedWidth)
        #expect(controller.setPersistentSidebarVisible(true))
        #expect(sidebar.view.frame.width == SidebarWidthPolicy.collapsedWidth)
        controller.view.frame.size.width = 1_600
        controller.view.layoutSubtreeIfNeeded()
        #expect(sidebar.view.frame.width == (expanded ? 420 : SidebarWidthPolicy.collapsedWidth))
    }

    @Test(
        arguments: await MainActor.run {
            [
                (CGFloat(187), CGFloat(1000), SidebarWidthPolicy.collapsedWidth),
                (245, 1000, SidebarWidthPolicy.collapsedWidth), (287, 1000, 287),
                (10, 1000, SidebarWidthPolicy.collapsedWidth), (900, 500, 500),
                (.infinity, 1000, SidebarWidthPolicy.collapsedWidth), (700, 40, SidebarWidthPolicy.collapsedWidth),
                (600, ContentView.minimumWindowWidth - ContentView.terminalMinimumWidth, SidebarWidthPolicy.collapsedWidth),
            ]
        })
    func clamp(width: CGFloat, max: CGFloat, expected: CGFloat) {
        #expect(SidebarSplitController.clampedWidth(width, maxWidth: max) == expected)
    }

}

@Suite("SidebarSplitController reclamp action")
@MainActor
struct SidebarSplitControllerReclampTests {
    typealias Action = SidebarSplitController.ReclampAction

    @Test(arguments: [
        (SidebarWidthPolicy.collapsedWidth, CGFloat(1000), CGFloat(296), false, false, Action.restoreExpanded(296)),
        (120, 1000, 296, false, true, .clamp(SidebarWidthPolicy.collapsedWidth)),
        (600, 240, 600, false, true, .clamp(SidebarWidthPolicy.collapsedWidth)),
        (SidebarWidthPolicy.collapsedWidth, 1000, 296, true, false, .none),
        (296, 1000, 296, false, false, .none),
    ])
    func reclamp(current: CGFloat, max: CGFloat, lastExpanded: CGFloat, rail: Bool, dragging: Bool, expected: Action) {
        #expect(
            SidebarSplitController.reclampAction(
                currentWidth: current, maxWidth: max, lastExpandedWidth: lastExpanded,
                userChoseRail: rail, isDraggingDivider: dragging) == expected)
    }

}
