import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import AwesoMuxTestSupport
import SwiftUI
import Testing
@testable import awesoMux

@Suite("Sidebar presentation behavior", .serialized)
@MainActor
struct SidebarPresentationBehaviorTests {
    private final class AnimationDriver {
        var presentationTranslation: CGFloat?
        var completions: [() -> Void] = []
        var requestCount = 0
    }
    private struct RootFixture: View {
        let value: String
        var body: some View { Text(value) }
    }

    enum UpdateMode: Equatable, Sendable {
        case hidden
        case overlay
        case midAnimation
        case persistent
    }

    struct RecoveryReductionCase: Sendable {
        let initialKeyboardFocus: Bool
        let movesKeyboardFocus: Bool
        let movesAccessibilityFocus: Bool
    }

    struct RepeatedResignationCase: Sendable, CustomTestStringConvertible {
        let name: String
        let requiresKeyboardFocus: Bool
        let requiresAccessibilityFocus: Bool
        let replacesAccessibilityElement: Bool

        var testDescription: String { name }
    }

    struct OwnerScopedRecoveryCase: Sendable, CustomTestStringConvertible {
        let name: String
        let requiresKeyboardFocus: Bool
        let requiresAccessibilityFocus: Bool

        var testDescription: String { name }
    }

    enum KeyViewVisibilityKind: Sendable {
        case zeroSize
        case offscreen
        case transparentAncestor
        case accessibilityHidden
        case visible
    }

    struct KeyViewVisibilityCase: Sendable, CustomTestStringConvertible {
        let name: String
        let kind: KeyViewVisibilityKind
        let expectedSuccess: Bool

        var testDescription: String { name }
    }

    enum InvalidAccessibilityDestinationKind: String, Sendable, CustomTestStringConvertible {
        case wrongWindow = "wrong window"
        case sidebar
        case hidden
        case notLocallyFocused = "not locally focused"
        case reportedFailure = "reported modality failure"

        var testDescription: String { rawValue }
    }

    private final class AccessibilityElementBox {
        var element: Any?
    }

    private final class AccessibilityRecordingView: NSView {
        var recordedAccessibilityHidden = false
        var accessibilityHiddenHistory: [Bool] = []
        override var acceptsFirstResponder: Bool { true }

        override func setAccessibilityHidden(_ accessibilityHidden: Bool) {
            recordedAccessibilityHidden = accessibilityHidden
            accessibilityHiddenHistory.append(accessibilityHidden)
            super.setAccessibilityHidden(accessibilityHidden)
        }
    }

    private final class FirstResponderView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private final class FocusReadinessWindow: NSWindow {
        var reportsKey = false
        var recordsMakeFirstResponder = false
        var refusesFirstResponderClear = false
        private(set) var recordedMakeFirstResponderCount = 0
        private(set) var refusedFirstResponderClearCount = 0

        override var isKeyWindow: Bool { reportsKey }

        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            if recordsMakeFirstResponder {
                recordedMakeFirstResponderCount += 1
            }
            if refusesFirstResponderClear, responder == nil {
                refusedFirstResponderClearCount += 1
                return false
            }
            return super.makeFirstResponder(responder)
        }
    }

    private final class AccessibilityFocusView: NSView {
        var onFocusChange: ((Bool) -> Void)?
        private var focused = false
        private(set) var accessibilityFocusRequestCount = 0

        override var acceptsFirstResponder: Bool { true }

        override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
            if accessibilityFocused {
                accessibilityFocusRequestCount += 1
            }
            focused = accessibilityFocused
            onFocusChange?(accessibilityFocused)
        }

        override func isAccessibilityFocused() -> Bool { focused }
    }

    private final class LifetimeToken {}

    @MainActor
    private struct ProductionFocusFixture {
        let selectedPane: TerminalPane
        let peerPane: TerminalPane
        let session: TerminalSession
        let sessionStore: SessionStore
        let runtime: GhosttyRuntime
        let peerSurface: GhosttySurfaceNSView
        let primarySafeFocus: FirstResponderView
        let sidebarFocus: AccessibilityFocusView
        let sidebarSearchField: NSSearchField
        let controller: SidebarSplitController
        let window: FocusReadinessWindow
        let focusPrimaryContent: (SidebarFocusHandoffRequest) -> SidebarFocusHandoffOutcome?

        init(
            notificationCenter: NotificationCenter = NotificationCenter(),
            focusedAccessibilityElement: AccessibilityElementBox? = nil,
            applicationIsActive: @escaping () -> Bool = { true }
        ) {
            let focusedAccessibilityElement =
                focusedAccessibilityElement ?? AccessibilityElementBox()
            let selectedPane = TerminalPane(
                title: "selected",
                workingDirectory: "/tmp/selected",
                executionPlan: .local)
            let peerPane = TerminalPane(
                title: "peer",
                workingDirectory: "/tmp/peer",
                executionPlan: .local)
            let session = TerminalSession(
                title: "split",
                workingDirectory: "/tmp/selected",
                layout: .split(
                    TerminalSplit(
                        orientation: .vertical,
                        first: .pane(selectedPane),
                        second: .pane(peerPane),
                        firstFraction: 0.5)),
                activePaneID: selectedPane.id)
            let sessionStore = SessionStore(
                groups: [SessionGroup(name: "awesoMux", sessions: [session])],
                selectedSessionID: session.id)
            let runtime = GhosttyRuntime()
            let peerSurface = runtime.surfaceView(
                sessionStore: sessionStore,
                session: session,
                pane: peerPane,
                enabledAgentRuntimeFileDropSources: [],
                grokIconEnabled: false)
            let sidebar = NSViewController()
            let sidebarFocus = AccessibilityFocusView(
                frame: CGRect(x: 16, y: 720, width: 120, height: 24))
            sidebar.view.addSubview(sidebarFocus)
            let sidebarSearchField = NSSearchField(
                frame: CGRect(x: 16, y: 680, width: 180, height: 24))
            sidebar.view.addSubview(sidebarSearchField)
            let detail = NSViewController()
            let primarySafeFocus = FirstResponderView(
                frame: CGRect(x: 20, y: 500, width: 180, height: 24))
            detail.view.addSubview(primarySafeFocus)
            peerSurface.frame = CGRect(x: 20, y: 20, width: 560, height: 420)
            detail.view.addSubview(peerSurface)
            sidebarFocus.nextKeyView = peerSurface
            peerSurface.nextKeyView = sidebarFocus
            let controller = SidebarSplitController(
                sidebar: sidebar,
                detail: detail,
                interactionFocusedAccessibilityElement: {
                    focusedAccessibilityElement.element
                },
                interactionNotificationCenter: notificationCenter,
                applicationIsActive: applicationIsActive)
            controller.loadViewIfNeeded()
            controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
            controller.view.layoutSubtreeIfNeeded()
            let window = FocusReadinessWindow(
                contentRect: controller.view.bounds,
                styleMask: [.titled],
                backing: .buffered,
                defer: false)
            window.contentViewController = controller
            window.awesoMuxWindowRole = .primaryContent
            window.alphaValue = 0
            window.reportsKey = true
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            controller.setSidebarWidth(300)
            controller.hasActiveSidebarAccessibilityFocus = {
                sidebarFocus.isAccessibilityFocused()
            }
            controller.sidebarAccessibilityFocusedElement = {
                sidebarFocus.isAccessibilityFocused() ? sidebarFocus : nil
            }
            let focusPrimaryContent = { request in
                let outcome = PrimaryContentFocusRouter.focus(
                    request,
                    sessionStore: sessionStore,
                    application: .shared,
                    primaryContentWindow: { _ in window },
                    applicationIsActive: applicationIsActive)
                if request.requiresAccessibilityFocus,
                    outcome?.accessibilityFocusSucceeded == true
                {
                    focusedAccessibilityElement.element = outcome?.destination
                }
                return outcome
            }
            controller.onSidebarFocusHandoff = focusPrimaryContent

            self.selectedPane = selectedPane
            self.peerPane = peerPane
            self.session = session
            self.sessionStore = sessionStore
            self.runtime = runtime
            self.peerSurface = peerSurface
            self.primarySafeFocus = primarySafeFocus
            self.sidebarFocus = sidebarFocus
            self.sidebarSearchField = sidebarSearchField
            self.controller = controller
            self.window = window
            self.focusPrimaryContent = focusPrimaryContent
        }

        func mountSelectedSurface() -> GhosttySurfaceNSView {
            let surface = runtime.surfaceView(
                sessionStore: sessionStore,
                session: session,
                pane: selectedPane,
                enabledAgentRuntimeFileDropSources: [],
                grokIconEnabled: false)
            mount(
                surface,
                isActive: true,
                in: controller.detailViewController.view,
                frame: CGRect(x: 600, y: 20, width: 560, height: 420))
            return surface
        }

        @discardableResult
        func mount(
            _ surface: GhosttySurfaceNSView,
            isActive: Bool,
            in root: NSView,
            frame: CGRect = CGRect(x: 20, y: 20, width: 560, height: 420)
        ) -> GhosttySurfaceContainerView {
            let container = GhosttySurfaceContainerView(contentSize: frame.size)
            container.frame = frame
            root.addSubview(container)
            container.mount(surface, isActive: isActive, contentSize: frame.size)
            return container
        }

        func cleanUp() {
            window.awesoMuxWindowRole = nil
            window.orderOut(nil)
            runtime.discardAllSurfaces()
        }
    }

    private func makeController(
        position: AppearanceConfig.SidebarPosition = .left,
        focusedAccessibilityElement: SidebarInteractionMonitor.FocusedAccessibilityElement? = nil
    ) -> (
        SidebarSplitController, NSViewController, NSViewController
    ) {
        let sidebar = NSViewController()
        sidebar.view = AccessibilityRecordingView()
        let detail = NSViewController()
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: detail,
            interactionFocusedAccessibilityElement: focusedAccessibilityElement,
            applicationIsActive: { true })
        controller.setSidebarPosition(position)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        return (controller, sidebar, detail)
    }

    private func hostInActiveWindow(
        _ controller: SidebarSplitController
    ) -> FocusReadinessWindow {
        let window = FocusReadinessWindow(
            contentRect: controller.view.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentViewController = controller
        window.alphaValue = 0
        window.reportsKey = true
        window.orderFrontRegardless()
        return window
    }

    private func makeControlledController(
        position: AppearanceConfig.SidebarPosition = .left,
        driver: AnimationDriver
    ) -> (SidebarSplitController, NSViewController, NSViewController) {
        let sidebar = NSViewController()
        sidebar.view = AccessibilityRecordingView()
        let detail = NSViewController()
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: detail,
            overlayPresentationTranslation: { driver.presentationTranslation },
            overlayAnimationRunner: { _, _, _, _, completion in
                driver.requestCount += 1
                driver.completions.append(completion)
            },
            applicationIsActive: { true })
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
        #expect(controller.sidebarHostClipViewForTesting.accessibilityIsIgnored())
        #expect(!controller.sidebarHostClipViewForTesting.isAccessibilityElement())
        #expect(sidebar.view.superview === controller.sidebarHostViewForTesting)
        #expect(controller.sidebarHostOccurrenceCountForTesting == 1)
        #expect(controller.sidebarSplitPaneWidthForTesting == 0)
        #expect(detail.view.frame == detailFrame)
        #expect(
            controller.view.subviews.firstIndex(of: detail.view.superview!)! < controller.view.subviews.firstIndex(
                of: controller.sidebarHostClipViewForTesting)!)
        if position == .left {
            #expect(controller.sidebarHostClipViewForTesting.frame.minX == 0)
        } else {
            #expect(controller.sidebarHostClipViewForTesting.frame.maxX == controller.view.bounds.maxX)
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
        #expect(sidebar.view.superview === controller.sidebarHostViewForTesting)
        #expect(controller.sidebarHostOccurrenceCountForTesting == 1)
        #expect(controller.sidebarHostClipViewForTesting.isHidden)
    }

    @Test(
        "animated overlay changes compositor transform without split geometry",
        arguments: [AppearanceConfig.SidebarPosition.left, .right])
    func compositorOnlyAnimation(position: AppearanceConfig.SidebarPosition) {
        let (controller, _, detail) = makeController(position: position)
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        let detailFrame = detail.view.frame
        let splitWidth = controller.sidebarSplitPaneWidthForTesting

        controller.setOverlayPresented(
            true, transition: .hover, reduceMotion: false)

        #expect(
            controller.sidebarHostViewForTesting.layer?.animation(
                forKey: SidebarOverlayAnimator.animationKey) != nil)
        #expect(controller.sidebarHostClipViewForTesting.frame.width == 300)
        #expect(controller.sidebarHostViewForTesting.frame.size == CGSize(width: 300, height: 800))
        #expect(controller.sidebarSplitPaneWidthForTesting == splitWidth)
        #expect(detail.view.frame == detailFrame)
    }

    @Test("overlay width selection updates live width without divider geometry")
    func overlayWidthSelectionIsCompositorOnly() {
        let (controller, _, detail) = makeController()
        controller.setSidebarWidth(300)
        controller.setPersistentSidebarVisible(false)
        controller.setOverlayPresentedImmediately(true)
        let detailFrame = detail.view.frame
        var liveWidths: [CGFloat] = []
        controller.onLiveWidthChange = { liveWidths.append($0) }

        controller.setSelectedSidebarWidth(SidebarWidthPolicy.collapsedWidth)

        // The terminal pane frame is the end-state proxy for "no divider geometry
        // moved": an overlay width change is compositor-only, so the split's panes
        // stay put.
        #expect(detail.view.frame == detailFrame)
        #expect(liveWidths == [SidebarWidthPolicy.collapsedWidth])
        #expect(
            controller.hostPresentationState.mode
                == .overlay(width: SidebarWidthPolicy.collapsedWidth))
    }

    @Test(
        "narrow-window overlay preserves the selected full width without changing split geometry",
        arguments: [AppearanceConfig.SidebarPosition.left, .right])
    func narrowWindowOverlayPreservesSelectedWidth(position: AppearanceConfig.SidebarPosition) {
        let (controller, _, detail) = makeController(position: position)
        controller.setSidebarWidth(SidebarWidthPolicy.collapsedWidth)
        controller.setPersistentSidebarVisible(false)
        controller.view.frame.size.width = 570
        controller.view.layoutSubtreeIfNeeded()
        let detailFrame = detail.view.frame

        controller.setSelectedSidebarWidth(300)
        controller.setOverlayPresentedImmediately(true)

        #expect(controller.sidebarHostClipViewForTesting.frame.width == 300)
        #expect(controller.hostModeForTesting == .overlay(width: 300))
        #expect(controller.sidebarSplitPaneWidthForTesting == 0)
        #expect(detail.view.frame == detailFrame)
    }

    @Test("initial overlay mount republishes the restored width after a persistent clamp")
    func initialOverlayMountRepublishesRestoredWidth() {
        let (controller, _, _) = makeController()
        let selectedWidth: CGFloat = 296
        controller.setSidebarWidth(selectedWidth)
        var liveWidths: [CGFloat] = []
        controller.onLiveWidthChange = { liveWidths.append($0) }

        controller.view.frame.size.width =
            ContentView.terminalMinimumWidth + SidebarWidthPolicy.collapsedWidth + 1
        controller.view.layoutSubtreeIfNeeded()
        #expect(liveWidths.last == SidebarWidthPolicy.collapsedWidth)

        controller.setPersistentSidebarVisible(false)
        liveWidths.removeAll()
        controller.setOverlayPresentedImmediately(true)

        let restoredLiveWidth = liveWidths.last
        #expect(restoredLiveWidth == selectedWidth)
        #expect(controller.hostModeForTesting == .overlay(width: selectedWidth))
        #expect(
            SidebarHiddenWidthTogglePolicy.targetWidth(
                currentWidth: SidebarHiddenWidthTogglePolicy.currentWidth(
                    committedWidth: selectedWidth,
                    liveWidth: restoredLiveWidth ?? 0,
                    isTemporarilyRevealed: true),
                lastNonCollapsedWidth: selectedWidth)
                == SidebarWidthPolicy.collapsedWidth)
    }

    @Test(
        "overlay normalizes invalid selected widths without applying the persistent ceiling",
        arguments: [CGFloat(-20), .infinity, .nan])
    func overlayNormalizesInvalidSelectedWidth(width: CGFloat) {
        let (controller, _, _) = makeController()
        controller.setPersistentSidebarVisible(false)

        controller.setSelectedSidebarWidth(width)
        controller.setOverlayPresentedImmediately(true)

        #expect(
            controller.hostModeForTesting
                == .overlay(width: SidebarWidthPolicy.collapsedWidth))
        #expect(
            controller.sidebarHostClipViewForTesting.frame.width
                == SidebarWidthPolicy.collapsedWidth)
    }

    @Test("Reduce Motion reveals immediately with aligned hit testing")
    func reduceMotionReveal() {
        let (controller, _, _) = makeController(position: .right)
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)

        controller.setOverlayPresented(true, transition: .hover, reduceMotion: true)

        #expect(
            controller.sidebarHostViewForTesting.layer?.animation(
                forKey: SidebarOverlayAnimator.animationKey) == nil)
        #expect(controller.sidebarHostViewForTesting.layer?.transform.m41 == 0)
        #expect(controller.sidebarHostClipViewForTesting.presentationTranslationX() == 0)
    }

    @Test("persistent restore invalidates an in-flight overlay completion")
    func persistentRestoreCancelsOverlay() throws {
        let driver = AnimationDriver()
        let (controller, sidebar, _) = makeControlledController(driver: driver)
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        controller.setOverlayPresented(true, transition: .hover, reduceMotion: false)
        let staleCompletion = try #require(driver.completions.last)

        #expect(controller.setPersistentSidebarVisible(true))
        staleCompletion()

        #expect(controller.hostModeForTesting == .persistent(width: 300))
        #expect(sidebar.view.superview === controller.sidebarHostViewForTesting)
        // Single host: the sidebar renders from the visible root container now.
        #expect(!controller.sidebarHostClipViewForTesting.isHidden)
    }

    @Test("overlay to persistent preserves a real search field editor")
    func overlayToPersistentPreservesSearchFieldEditor() throws {
        let (controller, sidebar, _) = makeController()
        let searchField = NSSearchField(
            frame: CGRect(x: 16, y: 720, width: 180, height: 24))
        sidebar.view.addSubview(searchField)
        let window = hostInActiveWindow(controller)
        defer { window.orderOut(nil) }
        controller.setSidebarWidth(300)
        _ = window.makeFirstResponder(nil)
        #expect(controller.setPersistentSidebarVisible(false))
        controller.setOverlayPresentedImmediately(true)
        searchField.selectText(nil)
        let fieldEditor = try #require(searchField.currentEditor() as? NSTextView)
        #expect(window.firstResponder === fieldEditor)
        // The disabled dual-host trace test used to pin single-publication; assert it
        // live here now that the reparenting handoff (and its double-publish risk) is gone.
        var livePublications = 0
        controller.onLiveWidthChange = { _ in livePublications += 1 }

        #expect(controller.setPersistentSidebarVisible(true))

        #expect(livePublications == 1)
        let responder = try #require(window.firstResponder as? NSView)
        let focusOwner = (responder as? NSTextView)?.delegate as? NSView ?? responder
        #expect(focusOwner === searchField)
        #expect(searchField.window === window)
        #expect(controller.hostModeForTesting == .persistent(width: 300))
        #expect(sidebar.view.superview === controller.sidebarHostViewForTesting)
    }

    @Test("persistent show fails closed when handoff prerequisites disappear")
    func persistentShowRollback() {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarWidth(300)
        controller.setPersistentSidebarVisible(false)
        controller.setEdgeTrackingEnabled(false)
        controller.sidebarHostViewForTesting.layer = nil

        #expect(!controller.setPersistentSidebarVisible(true))

        #expect(controller.hostModeForTesting == .hidden)
        #expect(controller.hostPresentationState.mode == .hidden)
        #expect(sidebar.view.superview === controller.sidebarHostViewForTesting)
        #expect(controller.sidebarHostClipViewForTesting.isHidden)
        #expect(controller.isEdgeTrackingVisibleForTesting)
    }

    @Test("persistent hide stays visible when required AX focus handoff fails")
    func persistentHideAbortsAfterFailedAccessibilityHandoff() {
        let (controller, sidebar, _) = makeController()
        let window = hostInActiveWindow(controller)
        defer { window.orderOut(nil) }
        controller.setSidebarWidth(300)
        controller.hasActiveSidebarAccessibilityFocus = { true }
        var handoffRequests: [SidebarFocusHandoffRequest] = []
        controller.onSidebarFocusHandoff = { request in
            handoffRequests.append(request)
            return nil
        }

        #expect(!controller.setPersistentSidebarVisible(false))

        #expect(
            handoffRequests
                == [
                    .init(
                        requiresKeyboardFocus: true,
                        requiresAccessibilityFocus: true)
                ])
        #expect(controller.hostModeForTesting == .persistent(width: 300))
        #expect(controller.hostPresentationState.mode == .persistent(width: 300))
        #expect((sidebar.view as? AccessibilityRecordingView)?.recordedAccessibilityHidden == false)
        #expect(controller.sidebarSplitPaneWidthForTesting == 300)
        #expect(!controller.isEdgeTrackingVisibleForTesting)
    }

    @Test("reported AX-only handoff success is rejected while global focus stays in sidebar")
    func staleImmediateAccessibilityHandoffFailsClosed() {
        let sidebar = NSViewController()
        let detail = NSViewController()
        let sidebarFocus = AccessibilityFocusView(
            frame: CGRect(x: 16, y: 680, width: 120, height: 24))
        let detailKeyboardFocus = FirstResponderView(
            frame: CGRect(x: 20, y: 20, width: 120, height: 24))
        let unrelatedGlobalFocus = AccessibilityFocusView(
            frame: CGRect(x: 20, y: 60, width: 120, height: 24))
        sidebar.view.addSubview(sidebarFocus)
        detail.view.addSubview(detailKeyboardFocus)
        detail.view.addSubview(unrelatedGlobalFocus)
        let focusedElement = AccessibilityElementBox()
        sidebarFocus.onFocusChange = { focused in
            if focused {
                focusedElement.element = sidebarFocus
            } else if focusedElement.element as? NSView === sidebarFocus {
                focusedElement.element = nil
            }
        }
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: detail,
            interactionFocusedAccessibilityElement: { focusedElement.element },
            applicationIsActive: { true })
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let window = hostInActiveWindow(controller)
        defer { window.orderOut(nil) }
        controller.setSidebarWidth(300)
        #expect(window.makeFirstResponder(detailKeyboardFocus))
        sidebarFocus.setAccessibilityFocused(true)
        controller.hasActiveSidebarAccessibilityFocus = {
            sidebarFocus.isAccessibilityFocused()
        }
        controller.sidebarAccessibilityFocusedElement = { sidebarFocus }
        var requests: [SidebarFocusHandoffRequest] = []
        controller.onSidebarFocusHandoff = { request in
            requests.append(request)
            unrelatedGlobalFocus.setAccessibilityFocused(true)
            return SidebarFocusHandoffOutcome(
                destination: unrelatedGlobalFocus, satisfying: request)
        }

        #expect(!controller.setPersistentSidebarVisible(false))

        #expect(
            requests
                == [
                    .init(
                        requiresKeyboardFocus: false,
                        requiresAccessibilityFocus: true)
                ])
        #expect(controller.hostModeForTesting == .persistent(width: 300))
        #expect(window.firstResponder === detailKeyboardFocus)
        #expect(focusedElement.element as? NSView === sidebarFocus)
        #expect(sidebarFocus.isAccessibilityFocused())

        controller.onSidebarFocusHandoff = { request in
            requests.append(request)
            unrelatedGlobalFocus.setAccessibilityFocused(true)
            focusedElement.element = unrelatedGlobalFocus
            return SidebarFocusHandoffOutcome(
                destination: unrelatedGlobalFocus, satisfying: request)
        }

        #expect(controller.setPersistentSidebarVisible(false))
        #expect(controller.hostModeForTesting == .hidden)
        #expect(focusedElement.element as? NSView === unrelatedGlobalFocus)
    }

    @Test(
        "AX handoff rejects a destination that is not the rendered local target",
        arguments: [
            InvalidAccessibilityDestinationKind.wrongWindow,
            .sidebar,
            .hidden,
            .notLocallyFocused,
            .reportedFailure,
        ])
    func accessibilityHandoffRejectsInvalidTypedDestination(
        kind: InvalidAccessibilityDestinationKind
    ) {
        let sidebar = NSViewController()
        let detail = NSViewController()
        let sidebarFocus = AccessibilityFocusView(
            frame: CGRect(x: 16, y: 680, width: 120, height: 24))
        let detailKeyboardFocus = FirstResponderView(
            frame: CGRect(x: 20, y: 20, width: 120, height: 24))
        let unrelatedGlobalFocus = AccessibilityFocusView(
            frame: CGRect(x: 20, y: 60, width: 120, height: 24))
        let detailCandidate = AccessibilityFocusView(
            frame: CGRect(x: 20, y: 100, width: 120, height: 24))
        sidebar.view.addSubview(sidebarFocus)
        detail.view.addSubview(detailKeyboardFocus)
        detail.view.addSubview(unrelatedGlobalFocus)
        detail.view.addSubview(detailCandidate)
        let focusedElement = AccessibilityElementBox()
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: detail,
            interactionFocusedAccessibilityElement: { focusedElement.element },
            applicationIsActive: { true })
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let window = hostInActiveWindow(controller)
        defer { window.orderOut(nil) }
        let wrongWindow = FocusReadinessWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        let wrongWindowCandidate = AccessibilityFocusView(
            frame: CGRect(x: 20, y: 20, width: 120, height: 24))
        wrongWindow.contentView = wrongWindowCandidate
        wrongWindow.alphaValue = 0
        wrongWindow.orderFrontRegardless()
        defer { wrongWindow.orderOut(nil) }
        controller.setSidebarWidth(300)
        #expect(window.makeFirstResponder(detailKeyboardFocus))
        sidebarFocus.setAccessibilityFocused(true)
        controller.hasActiveSidebarAccessibilityFocus = {
            sidebarFocus.isAccessibilityFocused()
        }
        controller.sidebarAccessibilityFocusedElement = { sidebarFocus }
        unrelatedGlobalFocus.setAccessibilityFocused(true)
        focusedElement.element = unrelatedGlobalFocus

        let destination: AccessibilityFocusView
        switch kind {
        case .wrongWindow:
            wrongWindowCandidate.setAccessibilityFocused(true)
            destination = wrongWindowCandidate
        case .sidebar:
            destination = sidebarFocus
        case .hidden:
            detailCandidate.isHidden = true
            detailCandidate.setAccessibilityFocused(true)
            destination = detailCandidate
        case .notLocallyFocused:
            destination = detailCandidate
        case .reportedFailure:
            detailCandidate.setAccessibilityFocused(true)
            destination = detailCandidate
        }
        controller.onSidebarFocusHandoff = { request in
            if kind == .reportedFailure {
                return SidebarFocusHandoffOutcome(
                    destination: destination,
                    keyboardFocusSucceeded: false,
                    accessibilityFocusSucceeded: false)
            }
            return SidebarFocusHandoffOutcome(
                destination: destination, satisfying: request)
        }

        #expect(!controller.setPersistentSidebarVisible(false))
        #expect(controller.hostModeForTesting == .persistent(width: 300))
        #expect(sidebarFocus.isAccessibilityFocused())
    }

    @Test(
        "keyboard handoff requires a positively rendered destination",
        arguments: [
            KeyViewVisibilityCase(
                name: "zero size",
                kind: .zeroSize,
                expectedSuccess: false),
            KeyViewVisibilityCase(
                name: "offscreen",
                kind: .offscreen,
                expectedSuccess: false),
            KeyViewVisibilityCase(
                name: "transparent ancestor",
                kind: .transparentAncestor,
                expectedSuccess: false),
            KeyViewVisibilityCase(
                name: "AX hidden but rendered",
                kind: .accessibilityHidden,
                expectedSuccess: true),
            KeyViewVisibilityCase(
                name: "visible",
                kind: .visible,
                expectedSuccess: true),
        ])
    func keyboardHandoffRequiresRenderedDestination(
        testCase: KeyViewVisibilityCase
    ) {
        let sidebar = NSViewController()
        let detail = NSViewController()
        let sidebarFocus = FirstResponderView(
            frame: CGRect(x: 16, y: 680, width: 120, height: 24))
        sidebar.view.addSubview(sidebarFocus)
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: detail,
            applicationIsActive: { true })
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let window = hostInActiveWindow(controller)
        defer { window.orderOut(nil) }
        controller.setSidebarWidth(300)
        controller.view.layoutSubtreeIfNeeded()
        let targetContainer = NSView(frame: detail.view.bounds)
        targetContainer.autoresizingMask = [.width, .height]
        detail.view.addSubview(targetContainer)
        let target = FirstResponderView(
            frame: CGRect(x: 20, y: 20, width: 120, height: 24))
        targetContainer.addSubview(target)
        switch testCase.kind {
        case .zeroSize:
            target.frame.size = .zero
        case .offscreen:
            target.frame.origin.x = detail.view.bounds.maxX + 20
        case .transparentAncestor:
            targetContainer.alphaValue = 0
        case .accessibilityHidden:
            target.setAccessibilityHidden(true)
        case .visible:
            break
        }
        #expect(window.makeFirstResponder(sidebarFocus))
        controller.onSidebarFocusHandoff = { request in
            #expect(request.requiresKeyboardFocus)
            #expect(!request.requiresAccessibilityFocus)
            guard window.makeFirstResponder(target) else { return nil }
            return SidebarFocusHandoffOutcome(destination: target, satisfying: request)
        }

        let succeeded = controller.setPersistentSidebarVisible(false)

        #expect(succeeded == testCase.expectedSuccess)
        if testCase.expectedSuccess {
            #expect(window.firstResponder === target)
        } else {
            #expect(window.firstResponder === sidebarFocus)
        }
    }

    @Test("persistent hide cannot fall through to a peer terminal during selected-surface remount")
    func persistentHideFailsClosedDuringSelectedSurfaceRemount() {
        let fixture = ProductionFocusFixture()
        defer { fixture.cleanUp() }
        #expect(fixture.window.makeFirstResponder(fixture.sidebarFocus))

        #expect(
            fixture.controller.deliverPersistentSidebarVisible(false) == .rejected)

        #expect(fixture.window.firstResponder === fixture.sidebarFocus)
        #expect(fixture.sessionStore.selectedSession?.activePaneID == fixture.selectedPane.id)
        #expect(fixture.controller.hostModeForTesting == .persistent(width: 300))
        #expect(fixture.controller.hostPresentationState.mode == .persistent(width: 300))
        #expect(fixture.controller.sidebarSplitPaneWidthForTesting == 300)
        #expect(!fixture.controller.isEdgeTrackingVisibleForTesting)

        let selectedSurface = fixture.mountSelectedSurface()
        #expect(
            fixture.controller.deliverPersistentSidebarVisible(false) == .applied)
        #expect(fixture.window.firstResponder === selectedSurface)
        #expect(fixture.controller.hostModeForTesting == .hidden)
    }

    @Test("persistent hide routes to the selected terminal instead of its key-loop peer")
    func persistentHideUsesAuthoritativeSelectedTerminal() {
        let fixture = ProductionFocusFixture()
        defer { fixture.cleanUp() }
        let selectedSurface = fixture.mountSelectedSurface()
        #expect(fixture.window.makeFirstResponder(fixture.sidebarFocus))

        #expect(fixture.controller.setPersistentSidebarVisible(false))

        #expect(fixture.window.firstResponder === selectedSurface)
        #expect(fixture.sessionStore.selectedSession?.activePaneID == fixture.selectedPane.id)
        #expect(fixture.controller.hostModeForTesting == .hidden)
        #expect(fixture.controller.hostPresentationState.mode == .hidden)
        #expect(fixture.controller.isEdgeTrackingVisibleForTesting)
    }

    @Test("Settings-key command hide defers primary keyboard and accessibility recovery")
    func settingsKeyCommandHideDefersPrimaryFocusRecovery() {
        let center = NotificationCenter()
        let fixture = ProductionFocusFixture(notificationCenter: center)
        defer { fixture.cleanUp() }
        let selectedSurface = fixture.mountSelectedSurface()
        let settingsFocus = FirstResponderView(
            frame: CGRect(x: 20, y: 20, width: 180, height: 24))
        let settingsWindow = FocusReadinessWindow(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        settingsWindow.contentView = settingsFocus
        settingsWindow.awesoMuxWindowRole = .settings
        settingsWindow.alphaValue = 0
        settingsWindow.orderFrontRegardless()
        defer {
            settingsWindow.awesoMuxWindowRole = nil
            settingsWindow.orderOut(nil)
        }
        #expect(fixture.window.makeFirstResponder(fixture.sidebarFocus))
        fixture.sidebarFocus.setAccessibilityFocused(true)
        let accessibilityFocusRequestCount =
            fixture.sidebarFocus.accessibilityFocusRequestCount
        fixture.window.recordsMakeFirstResponder = true
        fixture.window.reportsKey = false
        settingsWindow.reportsKey = true
        #expect(settingsWindow.makeFirstResponder(settingsFocus))

        #expect(fixture.controller.setPersistentSidebarVisible(false))

        #expect(fixture.controller.hostModeForTesting == .hidden)
        #expect(fixture.controller.hostPresentationState.mode == .hidden)
        #expect(fixture.controller.isEdgeTrackingVisibleForTesting)
        #expect(fixture.window.recordedMakeFirstResponderCount == 1)
        #expect(fixture.window.firstResponder !== fixture.sidebarFocus)
        #expect(
            fixture.sidebarFocus.accessibilityFocusRequestCount
                == accessibilityFocusRequestCount)
        #expect(settingsWindow.firstResponder === settingsFocus)

        settingsWindow.reportsKey = false
        fixture.window.reportsKey = true
        center.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)

        #expect(fixture.window.recordedMakeFirstResponderCount > 0)
        #expect(fixture.window.firstResponder === selectedSurface)
        #expect(selectedSurface.isAccessibilityFocused())
    }

    @Test(
        "Settings key-window focus cannot consume primary-owned recovery",
        arguments: [
            OwnerScopedRecoveryCase(
                name: "keyboard only",
                requiresKeyboardFocus: true,
                requiresAccessibilityFocus: false),
            OwnerScopedRecoveryCase(
                name: "accessibility only",
                requiresKeyboardFocus: false,
                requiresAccessibilityFocus: true),
            OwnerScopedRecoveryCase(
                name: "keyboard and accessibility",
                requiresKeyboardFocus: true,
                requiresAccessibilityFocus: true),
        ])
    func settingsFocusDoesNotConsumePrimaryOwnedRecovery(
        testCase: OwnerScopedRecoveryCase
    ) {
        let center = NotificationCenter()
        let focusedAccessibilityElement = AccessibilityElementBox()
        let fixture = ProductionFocusFixture(
            notificationCenter: center,
            focusedAccessibilityElement: focusedAccessibilityElement)
        defer { fixture.cleanUp() }
        let selectedSurface = fixture.mountSelectedSurface()
        let settingsKeyboardFocus = FirstResponderView(
            frame: CGRect(x: 20, y: 20, width: 180, height: 24))
        let settingsAccessibilityFocus = AccessibilityFocusView(
            frame: CGRect(x: 20, y: 60, width: 180, height: 24))
        let settingsContent = NSView(
            frame: CGRect(x: 0, y: 0, width: 480, height: 320))
        settingsContent.addSubview(settingsKeyboardFocus)
        settingsContent.addSubview(settingsAccessibilityFocus)
        let settingsWindow = FocusReadinessWindow(
            contentRect: settingsContent.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        settingsWindow.contentView = settingsContent
        settingsWindow.awesoMuxWindowRole = .settings
        settingsWindow.alphaValue = 0
        settingsWindow.orderFrontRegardless()
        defer {
            settingsWindow.awesoMuxWindowRole = nil
            settingsWindow.orderOut(nil)
        }
        var requests: [SidebarFocusHandoffRequest] = []
        fixture.controller.onSidebarFocusHandoff = { request in
            requests.append(request)
            return fixture.focusPrimaryContent(request)
        }
        if testCase.requiresKeyboardFocus {
            #expect(fixture.window.makeFirstResponder(fixture.sidebarFocus))
        } else {
            #expect(fixture.window.makeFirstResponder(selectedSurface))
        }
        if testCase.requiresAccessibilityFocus {
            fixture.sidebarFocus.setAccessibilityFocused(true)
            focusedAccessibilityElement.element = fixture.sidebarFocus
        }
        fixture.window.recordsMakeFirstResponder = true
        fixture.window.reportsKey = false
        settingsWindow.reportsKey = true
        #expect(settingsWindow.makeFirstResponder(settingsKeyboardFocus))

        #expect(fixture.controller.setPersistentSidebarVisible(false))

        settingsAccessibilityFocus.setAccessibilityFocused(true)
        focusedAccessibilityElement.element = settingsAccessibilityFocus
        center.post(name: NSWindow.didBecomeKeyNotification, object: settingsWindow)

        #expect(requests.isEmpty)
        #expect(
            fixture.window.recordedMakeFirstResponderCount
                == (testCase.requiresKeyboardFocus ? 1 : 0))
        #expect(settingsWindow.firstResponder === settingsKeyboardFocus)

        settingsWindow.reportsKey = false
        fixture.window.reportsKey = true
        center.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)

        #expect(
            requests
                == [
                    SidebarFocusHandoffRequest(
                        requiresKeyboardFocus: testCase.requiresKeyboardFocus,
                        requiresAccessibilityFocus: testCase.requiresAccessibilityFocus)
                ])
        #expect(fixture.window.firstResponder === selectedSurface)
        #expect(fixture.window.firstResponder !== fixture.sidebarFocus)
        #expect(!fixture.sidebarFocus.isAccessibilityFocused())
        if testCase.requiresAccessibilityFocus {
            #expect(selectedSurface.isAccessibilityFocused())
        }
        #expect(fixture.runtime.isSecureInputFocusedForTesting(fixture.selectedPane.id))
        #expect(!fixture.runtime.isSecureInputFocusedForTesting(fixture.peerPane.id))
    }

    @Test("Settings-key hide then show retires background focus recovery")
    func settingsKeyHideThenShowRetiresFocusRecovery() {
        let center = NotificationCenter()
        let fixture = ProductionFocusFixture(notificationCenter: center)
        defer { fixture.cleanUp() }
        let selectedSurface = fixture.mountSelectedSurface()
        var handoffRequests: [SidebarFocusHandoffRequest] = []
        fixture.controller.onSidebarFocusHandoff = { request in
            handoffRequests.append(request)
            return fixture.focusPrimaryContent(request)
        }
        let settingsFocus = FirstResponderView(
            frame: CGRect(x: 20, y: 20, width: 180, height: 24))
        let settingsWindow = FocusReadinessWindow(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        settingsWindow.contentView = settingsFocus
        settingsWindow.awesoMuxWindowRole = .settings
        settingsWindow.alphaValue = 0
        settingsWindow.orderFrontRegardless()
        defer {
            settingsWindow.awesoMuxWindowRole = nil
            settingsWindow.orderOut(nil)
        }
        #expect(fixture.window.makeFirstResponder(fixture.sidebarFocus))
        fixture.sidebarFocus.setAccessibilityFocused(true)
        let accessibilityFocusRequestCount =
            fixture.sidebarFocus.accessibilityFocusRequestCount
        fixture.window.recordsMakeFirstResponder = true
        fixture.window.reportsKey = false
        settingsWindow.reportsKey = true
        #expect(settingsWindow.makeFirstResponder(settingsFocus))

        #expect(fixture.controller.setPersistentSidebarVisible(false))
        #expect(fixture.controller.setPersistentSidebarVisible(true))

        #expect(fixture.controller.hostModeForTesting == .persistent(width: 300))
        #expect(fixture.controller.hostPresentationState.mode == .persistent(width: 300))
        #expect(fixture.controller.sidebarSplitPaneWidthForTesting == 300)
        #expect(!fixture.controller.isEdgeTrackingVisibleForTesting)
        #expect(fixture.window.recordedMakeFirstResponderCount == 1)
        #expect(
            fixture.sidebarFocus.accessibilityFocusRequestCount
                == accessibilityFocusRequestCount)
        #expect(fixture.sidebarFocus.isAccessibilityFocused())
        #expect(!selectedSurface.isAccessibilityFocused())
        #expect(settingsWindow.firstResponder === settingsFocus)
        #expect(handoffRequests.isEmpty)

        settingsWindow.reportsKey = false
        fixture.window.reportsKey = true
        center.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)

        #expect(handoffRequests.isEmpty)
        #expect(fixture.window.firstResponder !== fixture.sidebarFocus)
        #expect(fixture.window.firstResponder !== selectedSurface)
        #expect(fixture.sidebarFocus.isAccessibilityFocused())
        #expect(!selectedSurface.isAccessibilityFocused())
    }

    @Test("app resignation hides during a remount gap without routing to a peer terminal")
    func appResignationRemountFailureHidesAndRecovers() {
        let center = NotificationCenter()
        let fixture = ProductionFocusFixture(notificationCenter: center)
        defer { fixture.cleanUp() }
        _ = fixture.window.makeFirstResponder(nil)
        #expect(fixture.window.makeFirstResponder(fixture.primarySafeFocus))
        #expect(fixture.controller.setPersistentSidebarVisible(false))
        #expect(fixture.controller.setOverlayPresentedImmediately(true))
        #expect(fixture.window.makeFirstResponder(fixture.sidebarFocus))
        fixture.controller.onTrackingAvailabilityLost = { [weak controller = fixture.controller] in
            controller?.setOverlayPresentedImmediately(false)
        }

        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)

        #expect(fixture.controller.hostModeForTesting == .hidden)
        #expect(fixture.window.firstResponder !== fixture.peerSurface)
        #expect(fixture.sessionStore.selectedSession?.activePaneID == fixture.selectedPane.id)

        let selectedSurface = fixture.mountSelectedSurface()
        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)

        #expect(fixture.window.firstResponder === selectedSurface)
        #expect(fixture.sessionStore.selectedSession?.activePaneID == fixture.selectedPane.id)
    }

    @Test("app resignation clears a hidden search field editor through a remount gap")
    func appResignationClearsHiddenSearchFieldEditorThroughRemountGap() throws {
        let center = NotificationCenter.default
        var applicationIsActive = true
        let fixture = ProductionFocusFixture(
            notificationCenter: center,
            applicationIsActive: { applicationIsActive })
        defer { fixture.cleanUp() }
        var requests: [SidebarFocusHandoffRequest] = []
        fixture.controller.onSidebarFocusHandoff = { request in
            requests.append(request)
            return fixture.focusPrimaryContent(request)
        }
        fixture.controller.onTrackingAvailabilityLost = {
            [weak controller = fixture.controller] in
            controller?.setOverlayPresentedImmediately(false)
        }
        #expect(fixture.window.makeFirstResponder(fixture.primarySafeFocus))
        #expect(fixture.controller.setPersistentSidebarVisible(false))
        #expect(fixture.controller.setOverlayPresentedImmediately(true))
        fixture.sidebarSearchField.stringValue = "query"
        fixture.sidebarSearchField.selectText(nil)
        let fieldEditor = try #require(
            fixture.sidebarSearchField.currentEditor() as? NSTextView)
        #expect(fixture.window.firstResponder === fieldEditor)

        applicationIsActive = false
        fixture.window.reportsKey = false
        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)

        #expect(fixture.controller.hostModeForTesting == .hidden)
        #expect(fixture.window.firstResponder !== fieldEditor)
        #expect(fixture.sidebarSearchField.currentEditor() == nil)

        applicationIsActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        fixture.window.reportsKey = true
        center.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)

        let failedRequest = SidebarFocusHandoffRequest(
            requiresKeyboardFocus: true,
            requiresAccessibilityFocus: false)
        #expect(requests == [failedRequest])
        #expect(fixture.window.firstResponder !== fieldEditor)
        let keyEvent = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: fixture.window.windowNumber,
                context: nil,
                characters: "x",
                charactersIgnoringModifiers: "x",
                isARepeat: false,
                keyCode: 0x07))
        fixture.window.sendEvent(keyEvent)
        #expect(fixture.sidebarSearchField.stringValue == "query")

        let selectedSurface = fixture.mountSelectedSurface()

        #expect(fixture.window.firstResponder === selectedSurface)
        #expect(fixture.runtime.isSecureInputFocusedForTesting(fixture.selectedPane.id))
        #expect(fixture.sidebarSearchField.stringValue == "query")
    }

    @Test(
        "selected surface adoption retries pending primary focus recovery",
        arguments: [
            OwnerScopedRecoveryCase(
                name: "keyboard only",
                requiresKeyboardFocus: true,
                requiresAccessibilityFocus: false),
            OwnerScopedRecoveryCase(
                name: "accessibility only",
                requiresKeyboardFocus: false,
                requiresAccessibilityFocus: true),
            OwnerScopedRecoveryCase(
                name: "keyboard and accessibility",
                requiresKeyboardFocus: true,
                requiresAccessibilityFocus: true),
        ])
    func selectedSurfaceAdoptionRetriesPendingRecovery(
        testCase: OwnerScopedRecoveryCase
    ) {
        let center = NotificationCenter.default
        let focusedAccessibilityElement = AccessibilityElementBox()
        let fixture = ProductionFocusFixture(
            notificationCenter: center,
            focusedAccessibilityElement: focusedAccessibilityElement)
        defer { fixture.cleanUp() }
        var requests: [SidebarFocusHandoffRequest] = []
        fixture.controller.onSidebarFocusHandoff = { request in
            requests.append(request)
            return fixture.focusPrimaryContent(request)
        }
        #expect(fixture.window.makeFirstResponder(fixture.primarySafeFocus))
        #expect(fixture.controller.setPersistentSidebarVisible(false))
        if testCase.requiresKeyboardFocus {
            #expect(fixture.window.makeFirstResponder(fixture.sidebarFocus))
        } else {
            #expect(fixture.window.makeFirstResponder(fixture.primarySafeFocus))
        }
        if testCase.requiresAccessibilityFocus {
            fixture.sidebarFocus.setAccessibilityFocused(true)
            focusedAccessibilityElement.element = fixture.sidebarFocus
        }
        fixture.window.reportsKey = false

        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        fixture.window.reportsKey = true
        center.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)

        let expectedRequest = SidebarFocusHandoffRequest(
            requiresKeyboardFocus: testCase.requiresKeyboardFocus,
            requiresAccessibilityFocus: testCase.requiresAccessibilityFocus)
        #expect(requests == [expectedRequest])
        if !testCase.requiresKeyboardFocus {
            #expect(fixture.window.firstResponder === fixture.primarySafeFocus)
        } else {
            #expect(fixture.window.firstResponder !== fixture.sidebarFocus)
        }
        if testCase.requiresAccessibilityFocus {
            #expect(fixture.sidebarFocus.isAccessibilityFocused())
        }
        #expect(!fixture.runtime.isSecureInputFocusedForTesting(fixture.selectedPane.id))
        #expect(!fixture.runtime.isSecureInputFocusedForTesting(fixture.peerPane.id))

        let selectedSurface = fixture.mountSelectedSurface()

        let retryRequest = SidebarFocusHandoffRequest(
            requiresKeyboardFocus: false,
            requiresAccessibilityFocus: testCase.requiresAccessibilityFocus)
        let expectedRequests =
            testCase.requiresAccessibilityFocus
            ? [expectedRequest, retryRequest]
            : [expectedRequest]
        #expect(requests == expectedRequests)
        if testCase.requiresKeyboardFocus {
            #expect(fixture.window.firstResponder === selectedSurface)
        } else {
            #expect(fixture.window.firstResponder === fixture.primarySafeFocus)
        }
        if testCase.requiresAccessibilityFocus {
            #expect(selectedSurface.isAccessibilityFocused())
        }
        #expect(!fixture.sidebarFocus.isAccessibilityFocused())
        #expect(
            fixture.runtime.isSecureInputFocusedForTesting(fixture.selectedPane.id)
                == testCase.requiresKeyboardFocus)
        #expect(!fixture.runtime.isSecureInputFocusedForTesting(fixture.peerPane.id))

        _ = fixture.mountSelectedSurface()
        #expect(requests == expectedRequests)
    }

    @Test("peer surface adoption cannot satisfy selected-surface recovery")
    func peerSurfaceAdoptionDoesNotStealPendingRecovery() {
        let center = NotificationCenter.default
        let fixture = ProductionFocusFixture(notificationCenter: center)
        defer { fixture.cleanUp() }
        var requests: [SidebarFocusHandoffRequest] = []
        fixture.controller.onSidebarFocusHandoff = { request in
            requests.append(request)
            return fixture.focusPrimaryContent(request)
        }
        #expect(fixture.window.makeFirstResponder(fixture.primarySafeFocus))
        #expect(fixture.controller.setPersistentSidebarVisible(false))
        #expect(fixture.window.makeFirstResponder(fixture.sidebarFocus))
        fixture.window.reportsKey = false
        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        fixture.window.reportsKey = true
        center.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)
        let failedRequest = SidebarFocusHandoffRequest(
            requiresKeyboardFocus: true,
            requiresAccessibilityFocus: false)
        #expect(requests == [failedRequest])

        fixture.mount(
            fixture.peerSurface,
            isActive: false,
            in: fixture.controller.detailViewController.view)

        #expect(fixture.window.firstResponder !== fixture.sidebarFocus)
        #expect(!fixture.runtime.isSecureInputFocusedForTesting(fixture.peerPane.id))
        let selectedSurface = fixture.mountSelectedSurface()
        #expect(fixture.window.firstResponder === selectedSurface)
        #expect(fixture.runtime.isSecureInputFocusedForTesting(fixture.selectedPane.id))
    }

    @Test("wrong-window surface adoption cannot retry primary recovery")
    func wrongWindowSurfaceAdoptionDoesNotRetryPrimaryRecovery() {
        let center = NotificationCenter.default
        let fixture = ProductionFocusFixture(notificationCenter: center)
        defer { fixture.cleanUp() }
        var requests: [SidebarFocusHandoffRequest] = []
        fixture.controller.onSidebarFocusHandoff = { request in
            requests.append(request)
            return fixture.focusPrimaryContent(request)
        }
        #expect(fixture.window.makeFirstResponder(fixture.primarySafeFocus))
        #expect(fixture.controller.setPersistentSidebarVisible(false))
        #expect(fixture.window.makeFirstResponder(fixture.sidebarFocus))
        fixture.window.reportsKey = false
        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        fixture.window.reportsKey = true
        center.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)
        let failedRequest = SidebarFocusHandoffRequest(
            requiresKeyboardFocus: true,
            requiresAccessibilityFocus: false)
        #expect(requests == [failedRequest])

        let selectedSurface = fixture.runtime.surfaceView(
            sessionStore: fixture.sessionStore,
            session: fixture.session,
            pane: fixture.selectedPane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false)
        let wrongWindow = FocusReadinessWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        let wrongRoot = NSView(frame: wrongWindow.contentLayoutRect)
        wrongWindow.contentView = wrongRoot
        wrongWindow.alphaValue = 0
        wrongWindow.reportsKey = true
        wrongWindow.orderFrontRegardless()
        defer { wrongWindow.orderOut(nil) }
        fixture.mount(selectedSurface, isActive: true, in: wrongRoot)

        #expect(requests == [failedRequest])
        #expect(fixture.window.firstResponder !== fixture.sidebarFocus)

        let adoptedSurface = fixture.mountSelectedSurface()
        #expect(fixture.window.firstResponder === adoptedSurface)
        #expect(requests == [failedRequest])
    }

    @Test("surface adoption without pending recovery preserves legitimate focus")
    func surfaceAdoptionWithoutPendingRecoveryDoesNotStealFocus() {
        let fixture = ProductionFocusFixture(notificationCenter: .default)
        defer { fixture.cleanUp() }
        var requests: [SidebarFocusHandoffRequest] = []
        fixture.controller.onSidebarFocusHandoff = { request in
            requests.append(request)
            return nil
        }
        #expect(fixture.window.makeFirstResponder(fixture.primarySafeFocus))

        _ = fixture.mountSelectedSurface()

        #expect(requests.isEmpty)
        #expect(fixture.window.firstResponder === fixture.primarySafeFocus)
        #expect(!fixture.runtime.isSecureInputFocusedForTesting(fixture.selectedPane.id))
    }

    @Test("failed combined handoff restores a real search field editor owner")
    func failedCombinedHandoffRestoresSearchFieldOwner() throws {
        let (controller, sidebar, detail) = makeController()
        let searchField = NSSearchField(
            frame: CGRect(x: 16, y: 720, width: 180, height: 24))
        let sidebarAccessibilityFocus = AccessibilityFocusView(
            frame: CGRect(x: 16, y: 680, width: 120, height: 24))
        let detailDestination = AccessibilityFocusView(
            frame: CGRect(x: 20, y: 20, width: 120, height: 24))
        sidebar.view.addSubview(searchField)
        sidebar.view.addSubview(sidebarAccessibilityFocus)
        detail.view.addSubview(detailDestination)
        let window = hostInActiveWindow(controller)
        defer { window.orderOut(nil) }
        controller.setSidebarWidth(300)
        searchField.selectText(nil)
        let fieldEditor = try #require(searchField.currentEditor() as? NSTextView)
        #expect(window.firstResponder === fieldEditor)
        var focusedAccessibilityElement: AccessibilityFocusView?
        sidebarAccessibilityFocus.onFocusChange = { focused in
            if focused {
                focusedAccessibilityElement = sidebarAccessibilityFocus
            } else if focusedAccessibilityElement === sidebarAccessibilityFocus {
                focusedAccessibilityElement = nil
            }
        }
        detailDestination.onFocusChange = { focused in
            if focused {
                focusedAccessibilityElement = detailDestination
            } else if focusedAccessibilityElement === detailDestination {
                focusedAccessibilityElement = nil
            }
        }
        sidebarAccessibilityFocus.setAccessibilityFocused(true)
        controller.hasActiveSidebarAccessibilityFocus = { true }
        controller.sidebarAccessibilityFocusedElement = { focusedAccessibilityElement }
        var requests: [SidebarFocusHandoffRequest] = []
        controller.onSidebarFocusHandoff = { request in
            requests.append(request)
            #expect(window.makeFirstResponder(detailDestination))
            sidebarAccessibilityFocus.setAccessibilityFocused(false)
            detailDestination.setAccessibilityFocused(true)
            return nil
        }

        #expect(!controller.setPersistentSidebarVisible(false))

        let restoredResponder = try #require(window.firstResponder as? NSView)
        let restoredOwner =
            (restoredResponder as? NSTextView)?.delegate as? NSView
            ?? restoredResponder
        #expect(restoredOwner === searchField)
        #expect(
            requests
                == [
                    .init(
                        requiresKeyboardFocus: true,
                        requiresAccessibilityFocus: true)
                ])
        #expect(focusedAccessibilityElement === sidebarAccessibilityFocus)
        #expect(sidebarAccessibilityFocus.isAccessibilityFocused())
        #expect(controller.hostModeForTesting == .persistent(width: 300))
        #expect(controller.hostPresentationState.mode == .persistent(width: 300))
        #expect((sidebar.view as? AccessibilityRecordingView)?.recordedAccessibilityHidden == false)
        #expect(controller.sidebarSplitPaneWidthForTesting == 300)
        #expect(!controller.isEdgeTrackingVisibleForTesting)
    }

    @Test("failed AX handoff restores keyboard focus already in detail")
    func failedAccessibilityHandoffRestoresOriginalDetailFocus() throws {
        let (controller, sidebar, detail) = makeController()
        let sidebarAccessibilityFocus = AccessibilityFocusView(
            frame: CGRect(x: 16, y: 680, width: 120, height: 24))
        let originalDetailFocus = NSSearchField(
            frame: CGRect(x: 20, y: 20, width: 120, height: 24))
        let partialDetailDestination = AccessibilityFocusView(
            frame: CGRect(x: 20, y: 60, width: 120, height: 24))
        sidebar.view.addSubview(sidebarAccessibilityFocus)
        detail.view.addSubview(originalDetailFocus)
        detail.view.addSubview(partialDetailDestination)
        let window = hostInActiveWindow(controller)
        defer { window.orderOut(nil) }
        controller.setSidebarWidth(300)
        originalDetailFocus.selectText(nil)
        let originalFieldEditor = try #require(
            originalDetailFocus.currentEditor() as? NSTextView)
        #expect(window.firstResponder === originalFieldEditor)
        var focusedAccessibilityElement: AccessibilityFocusView?
        sidebarAccessibilityFocus.onFocusChange = { focused in
            if focused {
                focusedAccessibilityElement = sidebarAccessibilityFocus
            } else if focusedAccessibilityElement === sidebarAccessibilityFocus {
                focusedAccessibilityElement = nil
            }
        }
        partialDetailDestination.onFocusChange = { focused in
            if focused {
                focusedAccessibilityElement = partialDetailDestination
            } else if focusedAccessibilityElement === partialDetailDestination {
                focusedAccessibilityElement = nil
            }
        }
        sidebarAccessibilityFocus.setAccessibilityFocused(true)
        controller.hasActiveSidebarAccessibilityFocus = { true }
        controller.sidebarAccessibilityFocusedElement = { focusedAccessibilityElement }
        var requests: [SidebarFocusHandoffRequest] = []
        controller.onSidebarFocusHandoff = { request in
            requests.append(request)
            #expect(window.makeFirstResponder(partialDetailDestination))
            sidebarAccessibilityFocus.setAccessibilityFocused(false)
            partialDetailDestination.setAccessibilityFocused(true)
            return nil
        }

        #expect(!controller.setPersistentSidebarVisible(false))

        let restoredResponder = try #require(window.firstResponder as? NSView)
        let restoredOwner =
            (restoredResponder as? NSTextView)?.delegate as? NSView
            ?? restoredResponder
        #expect(restoredOwner === originalDetailFocus)
        #expect(
            requests
                == [
                    .init(
                        requiresKeyboardFocus: false,
                        requiresAccessibilityFocus: true)
                ])
        #expect(focusedAccessibilityElement === sidebarAccessibilityFocus)
        #expect(sidebarAccessibilityFocus.isAccessibilityFocused())
        #expect(controller.hostModeForTesting == .persistent(width: 300))
        #expect(controller.hostPresentationState.mode == .persistent(width: 300))
        #expect((sidebar.view as? AccessibilityRecordingView)?.recordedAccessibilityHidden == false)
        #expect(controller.sidebarSplitPaneWidthForTesting == 300)
        #expect(!controller.isEdgeTrackingVisibleForTesting)
    }

    @Test("overlay-focused side change preserves the visible host without a handoff")
    func overlayFocusedSideChangePreservesVisibleHost() {
        let center = NotificationCenter()
        let sidebar = NSViewController()
        sidebar.view = AccessibilityRecordingView()
        let accessibilityFocus = NSView()
        sidebar.view.addSubview(accessibilityFocus)
        var focusedAccessibilityElement: Any?
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: NSViewController(),
            interactionFocusedAccessibilityElement: { focusedAccessibilityElement },
            interactionNotificationCenter: center)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let window = NSWindow(
            contentRect: controller.view.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.setSidebarWidth(300)
        #expect(controller.setPersistentSidebarVisible(false))
        controller.setOverlayPresentedImmediately(true)
        focusedAccessibilityElement = accessibilityFocus
        center.post(name: NSWindow.didUpdateNotification, object: window)
        var requests: [SidebarFocusHandoffRequest] = []
        controller.onSidebarFocusHandoff = { request in
            requests.append(request)
            return nil
        }

        controller.setSidebarPosition(.right)

        #expect(requests.isEmpty)
        #expect(controller.hostModeForTesting == .overlay(width: 300))
        #expect(controller.hostPresentationState.mode == .overlay(width: 300))
        #expect(sidebar.view.superview === controller.sidebarHostViewForTesting)
        #expect(
            controller.sidebarHostClipViewForTesting.frame.maxX
                == controller.view.bounds.maxX)
        #expect(!controller.sidebarHostClipViewForTesting.isHidden)
        #expect((sidebar.view as? AccessibilityRecordingView)?.recordedAccessibilityHidden == false)
    }

    @Test("persistent hide fails closed when handoff prerequisites disappear")
    func persistentHideRollback() {
        let (controller, sidebar, _) = makeController(position: .right)
        controller.setSidebarWidth(300)
        controller.sidebarHostViewForTesting.layer = nil

        controller.setPersistentSidebarVisible(false)

        #expect(controller.hostModeForTesting == .hidden)
        #expect(controller.hostPresentationState.mode == .hidden)
        #expect(sidebar.view.superview === controller.sidebarHostViewForTesting)
        #expect(controller.sidebarHostClipViewForTesting.isHidden)
        #expect(controller.isEdgeTrackingVisibleForTesting)
    }

    @Test("unavailable-layer hide verifies keyboard and accessibility handoff before fallback")
    func unavailableLayerHideVerifiesFocusHandoff() {
        let focusedElement = AccessibilityElementBox()
        let (controller, sidebar, detail) = makeController(
            focusedAccessibilityElement: { focusedElement.element })
        let sidebarFocus = AccessibilityFocusView(
            frame: CGRect(x: 16, y: 720, width: 120, height: 24))
        let detailFocus = AccessibilityFocusView(
            frame: CGRect(x: 20, y: 20, width: 120, height: 24))
        sidebar.view.addSubview(sidebarFocus)
        detail.view.addSubview(detailFocus)
        sidebarFocus.onFocusChange = { focused in
            focusedElement.element = focused ? sidebarFocus : nil
        }
        detailFocus.onFocusChange = { focused in
            focusedElement.element = focused ? detailFocus : nil
        }
        let window = hostInActiveWindow(controller)
        defer { window.orderOut(nil) }
        controller.setSidebarWidth(300)
        #expect(window.makeFirstResponder(sidebarFocus))
        sidebarFocus.setAccessibilityFocused(true)
        controller.hasActiveSidebarAccessibilityFocus = { true }
        var requests: [SidebarFocusHandoffRequest] = []
        controller.onSidebarFocusHandoff = { request in
            requests.append(request)
            guard window.makeFirstResponder(detailFocus) else { return nil }
            sidebarFocus.setAccessibilityFocused(false)
            detailFocus.setAccessibilityFocused(true)
            guard detailFocus.isAccessibilityFocused() else { return nil }
            return SidebarFocusHandoffOutcome(destination: detailFocus, satisfying: request)
        }
        controller.sidebarHostViewForTesting.wantsLayer = false
        controller.sidebarHostViewForTesting.layer = nil

        #expect(controller.setPersistentSidebarVisible(false))

        #expect(
            requests
                == [
                    .init(
                        requiresKeyboardFocus: true,
                        requiresAccessibilityFocus: true)
                ])
        #expect(window.firstResponder === detailFocus)
        #expect(!sidebarFocus.isAccessibilityFocused())
        #expect(detailFocus.isAccessibilityFocused())
        #expect(controller.hostModeForTesting == .hidden)
        #expect(controller.hostPresentationState.mode == .hidden)
        #expect((sidebar.view as? AccessibilityRecordingView)?.recordedAccessibilityHidden == true)
        #expect(controller.isEdgeTrackingVisibleForTesting)
    }

    @Test("unavailable-layer handoff failure leaves persistent presentation unchanged")
    func unavailableLayerHideFailsClosed() {
        let (controller, sidebar, _) = makeController()
        let sidebarFocus = AccessibilityFocusView(
            frame: CGRect(x: 16, y: 720, width: 120, height: 24))
        sidebar.view.addSubview(sidebarFocus)
        let window = hostInActiveWindow(controller)
        defer { window.orderOut(nil) }
        controller.setSidebarWidth(300)
        #expect(window.makeFirstResponder(sidebarFocus))
        sidebarFocus.setAccessibilityFocused(true)
        controller.hasActiveSidebarAccessibilityFocus = { true }
        var requests: [SidebarFocusHandoffRequest] = []
        controller.onSidebarFocusHandoff = { request in
            requests.append(request)
            return nil
        }
        controller.sidebarHostViewForTesting.wantsLayer = false
        controller.sidebarHostViewForTesting.layer = nil

        #expect(!controller.setPersistentSidebarVisible(false))

        #expect(
            requests
                == [
                    .init(
                        requiresKeyboardFocus: true,
                        requiresAccessibilityFocus: true)
                ])
        #expect(window.firstResponder === sidebarFocus)
        #expect(sidebarFocus.isAccessibilityFocused())
        #expect(controller.hostModeForTesting == .persistent(width: 300))
        #expect(controller.hostPresentationState.mode == .persistent(width: 300))
        #expect((sidebar.view as? AccessibilityRecordingView)?.recordedAccessibilityHidden == false)
        #expect(controller.sidebarSplitPaneWidthForTesting == 300)
        #expect(!controller.isEdgeTrackingVisibleForTesting)
    }

    @Test(
        "authoritative host state survives overlay phases and stale completion",
        arguments: [AppearanceConfig.SidebarPosition.left, .right]
    )
    func authoritativeOverlayPhases(position: AppearanceConfig.SidebarPosition) {
        let driver = AnimationDriver()
        let (controller, _, _) = makeControlledController(position: position, driver: driver)
        controller.setSidebarWidth(300)
        controller.setPersistentSidebarVisible(false)

        controller.setOverlayPresented(true, transition: .hover, reduceMotion: false)
        let revealCompletion = driver.completions[0]
        #expect(controller.hostPresentationState.isOverlayAnimating)
        #expect(controller.hostPresentationState.mode == .overlay(width: 300))
        #expect(controller.hostPresentationState.effectiveVisibleWidth == 300)
        #expect(controller.hostPresentationState.titlebarTranslationX == 0)
        let midReveal: CGFloat = position == .left ? -120 : 120
        driver.presentationTranslation = midReveal
        #expect(controller.hostPresentationState.currentTitlebarTranslationX == midReveal)
        driver.presentationTranslation = nil
        revealCompletion()
        #expect(!controller.hostPresentationState.isOverlayAnimating)
        #expect(controller.hostPresentationState.mode == .overlay(width: 300))

        #expect(
            controller.setOverlayPresented(
                false, transition: .hover, reduceMotion: false))
        let staleHide = driver.completions[1]
        #expect(controller.hostPresentationState.isOverlayAnimating)
        #expect(controller.hostPresentationState.mode == .overlay(width: 300))
        #expect(
            controller.hostPresentationState.titlebarTranslationX
                == SidebarOverlayAnimator.hiddenTranslation(width: 300, position: position))
        let midHide: CGFloat = position == .left ? -180 : 180
        driver.presentationTranslation = midHide
        #expect(controller.hostPresentationState.currentTitlebarTranslationX == midHide)
        driver.presentationTranslation = nil
        controller.setOverlayPresented(true, transition: .hover, reduceMotion: false)
        #expect(controller.hostPresentationState.isOverlayAnimating)
        #expect(controller.hostPresentationState.titlebarTranslationX == 0)
        staleHide()
        #expect(controller.hostPresentationState.mode == .overlay(width: 300))
        driver.completions[2]()
        #expect(!controller.hostPresentationState.isOverlayAnimating)
        #expect(controller.hostPresentationState.mode == .overlay(width: 300))

        controller.setOverlayPresented(false, transition: .hover, reduceMotion: false)
        driver.completions[3]()
        #expect(controller.hostPresentationState.mode == .hidden)
        #expect(controller.hostPresentationState.effectiveVisibleWidth == 0)
        #expect(
            controller.hostPresentationState.titlebarTranslationX
                == SidebarOverlayAnimator.hiddenTranslation(width: 300, position: position))
    }

    @Test("titlebar visible width follows presentation translation on both sides")
    func titlebarVisibleWidthFollowsPresentationTranslation() {
        let state = SidebarHostPresentationState(mode: .hidden)
        state.beginOverlayTransition(presented: false, width: 300, position: .left)

        state.overlayPresentationTranslation = { -300 }
        #expect(state.currentTitlebarVisibleWidth(position: .left) == 0)
        state.overlayPresentationTranslation = { -180 }
        #expect(state.currentTitlebarVisibleWidth(position: .left) == 120)
        state.overlayPresentationTranslation = { 0 }
        #expect(state.currentTitlebarVisibleWidth(position: .left) == 300)
        state.overlayPresentationTranslation = { -180 }
        #expect(state.currentTitlebarVisibleWidth(position: .left) == 120)

        state.overlayPresentationTranslation = { 180 }
        #expect(state.currentTitlebarVisibleWidth(position: .right) == 120)
    }

    @Test("titlebar visible width clamps invalid presentation geometry")
    func titlebarVisibleWidthClampsInvalidPresentationGeometry() {
        let state = SidebarHostPresentationState(mode: .hidden)
        state.beginOverlayTransition(presented: true, width: 300, position: .left)

        state.overlayPresentationTranslation = { -600 }
        #expect(state.currentTitlebarVisibleWidth(position: .left) == 0)
        #expect(
            state.currentTitlebarVisibleWidth(position: .left, translation: .infinity) == 0)

        state.beginOverlayTransition(presented: true, width: .infinity, position: .right)
        state.overlayPresentationTranslation = { 0 }
        #expect(state.currentTitlebarVisibleWidth(position: .right) == 0)
    }

    @Test(
        "titlebar translation falls back to the stored target before any presentation layer",
        arguments: [AppearanceConfig.SidebarPosition.left, .right]
    )
    func firstRevealFallsBackWithoutPresentationLayer(
        position: AppearanceConfig.SidebarPosition
    ) {
        let hidden = SidebarOverlayAnimator.hiddenTranslation(width: 300, position: position)
        let state = SidebarHostPresentationState(mode: .hidden)

        // Settled hidden with no animator/closure wired yet: the deterministic
        // stored target is the only source.
        state.beginOverlayTransition(presented: false, width: 300, position: position)
        #expect(state.currentTitlebarTranslationX == hidden)
        #expect(state.currentTitlebarVisibleWidth(position: position) == 0)

        // The very first reveal renders before the presentation layer exists — the
        // fallback must read the presented target (0), not a live layer.
        state.beginOverlayTransition(presented: true, width: 300, position: position)
        #expect(state.currentTitlebarTranslationX == 0)
        #expect(state.currentTitlebarVisibleWidth(position: position) == 300)

        // A wired-but-empty presentation layer (animator present, layer not yet
        // sampling / returning non-finite) still falls through to the stored target.
        state.overlayPresentationTranslation = { nil }
        #expect(state.currentTitlebarTranslationX == 0)
        state.overlayPresentationTranslation = { .nan }
        #expect(state.currentTitlebarTranslationX == 0)
    }

    @Test(
        "overlay relayout reframes titlebar presentation width without dropping the animation",
        arguments: [AppearanceConfig.SidebarPosition.left, .right]
    )
    func overlayReframeUpdatesTitlebarPresentationWidth(
        position: AppearanceConfig.SidebarPosition
    ) {
        let state = SidebarHostPresentationState(mode: .overlay(width: 300))
        state.beginOverlayTransition(presented: true, width: 300, position: position)
        state.setOverlayAnimating(true)

        // Sample a mid-reveal translation (60% revealed at width 300).
        let mid: CGFloat = position == .left ? -120 : 120
        state.overlayPresentationTranslation = { mid }
        #expect(state.currentTitlebarVisibleWidth(position: position) == 180)

        // A divider drag mid-reveal drives publishOverlayLayout -> settle(.overlay,
        // newWidth): the width republishes while the overlay keeps animating (the
        // reframe path). The animating flag must survive the relayout...
        state.settle(mode: .overlay(width: 500), effectiveVisibleWidth: 500)
        #expect(state.isOverlayAnimating)
        #expect(state.titlebarPresentationWidth == 500)
        // ...and visible width now tracks the new presentation width at the same
        // sampled translation.
        #expect(
            state.currentTitlebarVisibleWidth(position: position, translation: mid)
                == 500 - abs(mid))
    }

    @Test("Reduce Motion keeps titlebar and overlay transition targets instant")
    func reduceMotionTitlebarParity() {
        let (controller, _, _) = makeController(position: .right)
        controller.setSidebarWidth(300)
        controller.setPersistentSidebarVisible(false)

        controller.setOverlayPresented(true, transition: .hover, reduceMotion: true)
        #expect(controller.hostPresentationState.titlebarTranslationX == 0)
        #expect(controller.hostPresentationState.currentTitlebarTranslationX == 0)

        controller.setOverlayPresented(false, transition: .hover, reduceMotion: true)
        #expect(controller.hostPresentationState.titlebarTranslationX == 300)
        #expect(controller.hostPresentationState.currentTitlebarTranslationX == 300)
    }

    @Test("settled persistent and hidden commands are idempotent")
    func settledVisibilityCommandsAreIdempotent() {
        let (controller, _, _) = makeController()
        controller.setSidebarWidth(300)
        // A width republish is the observable "the command did geometry work" signal;
        // an already-settled command must produce none.
        var liveWidthChanges = 0
        controller.onLiveWidthChange = { _ in liveWidthChanges += 1 }

        // Already persistent: re-showing does no work.
        controller.setPersistentSidebarVisible(true)
        #expect(liveWidthChanges == 0)
        #expect(controller.hostModeForTesting == .persistent(width: 300))

        controller.setPersistentSidebarVisible(false)
        #expect(controller.hostModeForTesting == .hidden)

        // Already hidden: re-hiding does no work and leaves the settled mode intact.
        liveWidthChanges = 0
        controller.setPersistentSidebarVisible(false)
        #expect(liveWidthChanges == 0)
        #expect(controller.hostModeForTesting == .hidden)
    }

    @Test("controller detach invalidates stale animation completion")
    func detachInvalidatesCompletion() {
        let driver = AnimationDriver()
        let (controller, sidebar, _) = makeControlledController(driver: driver)
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        controller.setOverlayPresented(true, transition: .hover, reduceMotion: false)
        let staleCompletion = driver.completions[0]

        controller.viewWillDisappear()
        staleCompletion()

        #expect(controller.hostModeForTesting == .hidden)
        #expect(sidebar.view.superview === controller.sidebarHostViewForTesting)
        #expect(controller.sidebarHostClipViewForTesting.isHidden)
    }

    @Test("persistent disappearance preserves ownership, hides AX, and restores on attach")
    func persistentDisappearPreservesSidebar() {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarWidth(300)

        controller.viewWillDisappear()

        #expect(controller.hostModeForTesting == .persistent(width: 300))
        #expect(sidebar.view.superview === controller.sidebarHostViewForTesting)
        #expect(controller.sidebarHostClipViewForTesting.isHidden)
        #expect((sidebar.view as? AccessibilityRecordingView)?.recordedAccessibilityHidden == true)
        controller.viewWillAppear()
        #expect((sidebar.view as? AccessibilityRecordingView)?.recordedAccessibilityHidden == false)
        #expect(controller.interactionObserverCountForTesting == 0)
        // Reattach must un-hide the host and re-mirror the reserved pane immediately,
        // not defer to a later layout tick (INT-845): a persistently-visible sidebar
        // would otherwise stay invisible after a detach/reattach cycle.
        #expect(!controller.sidebarHostClipViewForTesting.isHidden)
        #expect(controller.sidebarHostFrameForTesting == controller.sidebarPaneFrameForTesting)
    }

    @Test("window removal and re-add preserve persistent semantics and restore AX")
    func windowDetachAndReattach() {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarWidth(300)
        var availabilityLosses = 0
        var edgeMoves = 0
        var edgeExits = 0
        var liveWidths = 0
        var commits = 0
        var focusHandoffs = 0
        controller.onTrackingAvailabilityLost = { availabilityLosses += 1 }
        controller.onEdgePointerMove = { _, _ in edgeMoves += 1 }
        controller.onEdgeExit = { edgeExits += 1 }
        controller.onLiveWidthChange = { _ in liveWidths += 1 }
        controller.onCommitWidth = { _ in commits += 1 }
        controller.onSidebarFocusHandoff = { _ in
            focusHandoffs += 1
            return nil
        }
        let window = hostInActiveWindow(controller)
        defer { window.orderOut(nil) }
        #expect(controller.interactionObserverCountForTesting == 0)

        window.contentView = NSView()

        #expect(controller.hostModeForTesting == .persistent(width: 300))
        #expect(sidebar.view.superview === controller.sidebarHostViewForTesting)
        #expect((sidebar.view as? AccessibilityRecordingView)?.recordedAccessibilityHidden == true)
        #expect(controller.interactionObserverCountForTesting == 0)
        #expect(!controller.isFinalizedForTesting)
        let lossesAfterDetach = availabilityLosses
        #expect(lossesAfterDetach > 0)

        window.contentView = controller.view

        #expect(controller.hostModeForTesting == .persistent(width: 300))
        #expect((sidebar.view as? AccessibilityRecordingView)?.recordedAccessibilityHidden == false)
        #expect(controller.interactionObserverCountForTesting == 0)
        controller.simulateEdgePointerMoveForTesting(x: 10, width: 40)
        controller.simulateEdgeExitForTesting()
        controller.simulateTrackingAvailabilityLostForTesting()
        controller.setSidebarWidth(320)
        controller.simulateDividerDragCompletionForTesting()
        #expect(window.makeFirstResponder(sidebar.view))
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        controller.setPersistentSidebarVisible(false)

        #expect(edgeMoves == 1)
        #expect(edgeExits == 1)
        #expect(liveWidths > 0)
        #expect(commits == 1)
        #expect(focusHandoffs == 1)
        #expect(availabilityLosses == lossesAfterDetach + 1)
    }

    @Test("active accessibility focus retains overlay and cancels hide")
    func accessibilityFocusRetainsOverlay() {
        let driver = AnimationDriver()
        let (controller, sidebar, _) = makeControlledController(driver: driver)
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        controller.setOverlayPresented(true, transition: .hover, reduceMotion: false)
        driver.completions[0]()
        controller.hasActiveSidebarAccessibilityFocus = { true }
        let requestsBeforeHide = driver.requestCount

        controller.setOverlayPresented(false, transition: .hover, reduceMotion: false)

        #expect(driver.requestCount == requestsBeforeHide)
        #expect(controller.hostModeForTesting == .overlay(width: 300))
        #expect((sidebar.view as? AccessibilityRecordingView)?.recordedAccessibilityHidden == false)
    }

    @Test("window updates never poll accessibility, including during transient overlay")
    func windowUpdatesNeverPollAccessibility() {
        let center = NotificationCenter()
        var accessibilityQueryCount = 0
        let controller = SidebarSplitController(
            sidebar: NSViewController(),
            detail: NSViewController(),
            interactionFocusedAccessibilityElement: {
                accessibilityQueryCount += 1
                return nil
            },
            interactionNotificationCenter: center)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let window = NSWindow(
            contentRect: controller.view.bounds,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.view
        accessibilityQueryCount = 0

        center.post(name: NSWindow.didUpdateNotification, object: window)
        center.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(accessibilityQueryCount == 0)

        controller.setSidebarHidden(true)
        accessibilityQueryCount = 0
        center.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(accessibilityQueryCount == 0)

        controller.setOverlayPresentedImmediately(true)
        accessibilityQueryCount = 0
        center.post(name: NSWindow.didUpdateNotification, object: window)
        center.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(accessibilityQueryCount == 0)
    }

    @Test("live AX rescue survives window updates and clears when AX focus leaves")
    func liveAccessibilityRescueDoesNotOscillate() async throws {
        let suiteName = "SidebarPresentationBehaviorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SidebarPresentationPreferenceStore(defaults: defaults)
        store.saveHidden(true)
        let gate = TestScheduler()
        let model = SidebarPresentationModel(store: store, delay: { await gate.wait(for: $0) })
        let center = NotificationCenter()
        let sidebar = NSViewController()
        sidebar.view = AccessibilityRecordingView()
        let accessibilityFocus = NSView()
        sidebar.view.addSubview(accessibilityFocus)
        var focusedAccessibilityElement: Any?
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: NSViewController(),
            interactionFocusedAccessibilityElement: { focusedAccessibilityElement },
            interactionNotificationCenter: center,
            applicationIsActive: { true })
        controller.onSidebarInteractionChanged = model.sidebarInteractionChanged
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let window = NSWindow(
            contentRect: controller.view.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        model.pointerMoved(x: 15, width: 100, position: .left)
        controller.setOverlayPresentedImmediately(true)

        model.trackingRegionExited()
        #expect(await waitUntil { gate.sleeperCount == 1 })
        focusedAccessibilityElement = accessibilityFocus
        gate.advanceOneCycle()
        #expect(await waitUntil { model.proximityState == .dormant })

        controller.setOverlayPresentedImmediately(false)
        #expect(model.proximityState == .revealed)
        #expect(controller.hostModeForTesting == .overlay(width: 300))
        let sleepCountAfterRescue = gate.sleepCallCount

        for _ in 0..<100 {
            center.post(name: NSWindow.didUpdateNotification, object: window)
        }
        await Task.yield()
        #expect(gate.sleepCallCount == sleepCountAfterRescue)
        #expect(model.proximityState == .revealed)

        focusedAccessibilityElement = nil
        center.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(await waitUntil { gate.sleepCallCount == sleepCountAfterRescue + 1 })
        gate.advanceOneCycle()
        #expect(await waitUntil { model.proximityState == .dormant })
        controller.setOverlayPresentedImmediately(false)
        #expect(controller.hostModeForTesting == .hidden)
    }

    @Test("interaction observers exist only for a transient overlay")
    func interactionObserversFollowOverlayLifecycle() {
        let (controller, _, _) = makeController()
        controller.setSidebarWidth(300)
        #expect(controller.interactionObserverCountForTesting == 0)

        controller.setSidebarHidden(true)
        #expect(controller.interactionObserverCountForTesting == 0)

        controller.setOverlayPresentedImmediately(true)
        #expect(controller.interactionObserverCountForTesting == 4)

        controller.setOverlayPresentedImmediately(false)
        #expect(controller.interactionObserverCountForTesting == 0)

        controller.setPersistentSidebarVisible(true)
        #expect(controller.interactionObserverCountForTesting == 0)
    }

    @Test("stale AX focus cannot resurrect a detached hidden sidebar after reattach")
    func staleAccessibilityFocusDoesNotResurrectAfterReattach() throws {
        let suiteName = "SidebarPresentationBehaviorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SidebarPresentationPreferenceStore(defaults: defaults)
        store.saveHidden(true)
        let model = SidebarPresentationModel(store: store)
        let center = NotificationCenter()
        let sidebar = NSViewController()
        sidebar.view = AccessibilityRecordingView()
        let accessibilityFocus = NSView()
        sidebar.view.addSubview(accessibilityFocus)
        var focusedAccessibilityElement: Any?
        var accessibilityQueryCount = 0
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: NSViewController(),
            interactionFocusedAccessibilityElement: {
                accessibilityQueryCount += 1
                return focusedAccessibilityElement
            },
            interactionNotificationCenter: center)
        controller.onSidebarInteractionChanged = model.sidebarInteractionChanged
        controller.onTrackingAvailabilityLost = model.invalidateTransientState
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let window = NSWindow(
            contentRect: controller.view.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.setSidebarWidth(300)
        #expect(controller.setPersistentSidebarVisible(false))
        model.pointerMoved(x: 15, width: 100, position: .left)
        #expect(controller.setOverlayPresentedImmediately(true))
        focusedAccessibilityElement = accessibilityFocus
        #expect(controller.setOverlayPresentedImmediately(false))
        #expect(controller.hostModeForTesting == .overlay(width: 300))

        controller.viewWillDisappear()
        #expect(model.proximityState == .dormant)
        #expect(controller.hostModeForTesting == .hidden)
        let queryCountAfterDetach = accessibilityQueryCount

        controller.viewWillAppear()
        for _ in 0..<100 {
            center.post(name: NSWindow.didUpdateNotification, object: window)
        }
        center.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        center.post(name: NSMenu.didEndTrackingNotification, object: nil)
        controller.setSidebarPosition(.right)

        #expect(accessibilityQueryCount == queryCountAfterDetach)
        #expect(model.proximityState == .dormant)
        #expect(controller.hostModeForTesting == .hidden)
    }

    @Test("passive overlay reveal preserves the detail first responder")
    func passiveRevealPreservesResponder() {
        let driver = AnimationDriver()
        let (controller, _, detail) = makeControlledController(driver: driver)
        let responder = FirstResponderView()
        detail.view.addSubview(responder)
        let window = NSWindow(
            contentRect: controller.view.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = controller.view
        #expect(window.makeFirstResponder(responder))
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)

        controller.setOverlayPresented(true, transition: .hover, reduceMotion: false)
        #expect(window.firstResponder === responder)
        driver.completions[0]()
        #expect(window.firstResponder === responder)
    }

    @Test(
        "collapsed rail tile coordinates survive overlay reparent on both sides",
        arguments: [AppearanceConfig.SidebarPosition.left, .right])
    func collapsedRailCoordinateStability(position: AppearanceConfig.SidebarPosition) {
        let (controller, sidebar, _) = makeController(position: position)
        controller.setSidebarWidth(SidebarWidthPolicy.collapsedWidth)
        let tile = NSView(
            frame: CGRect(x: 8, y: 123, width: SidebarWidthPolicy.collapsedWidth - 16, height: 44))
        sidebar.view.addSubview(tile)
        let before = sidebar.view.convert(tile.frame, to: controller.view)
        let beforeInward = position == .left ? before.maxX : before.minX

        controller.setSidebarHidden(true)
        controller.setOverlayPresentedImmediately(true)
        let after = sidebar.view.convert(tile.frame, to: controller.view)
        let afterInward = position == .left ? after.maxX : after.minX

        #expect(after.origin.y == before.origin.y)
        #expect(afterInward == beforeInward)
    }

    @Test("AX descendants stay hidden until full reveal and hide before movement")
    func accessibilityExposurePhases() {
        let driver = AnimationDriver()
        let (controller, sidebar, _) = makeControlledController(driver: driver)
        let recorder = sidebar.view as! AccessibilityRecordingView
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        #expect(recorder.recordedAccessibilityHidden)

        controller.setOverlayPresented(true, transition: .hover, reduceMotion: false)
        #expect(recorder.recordedAccessibilityHidden)
        driver.completions[0]()
        #expect(!recorder.recordedAccessibilityHidden)

        controller.hasActiveSidebarAccessibilityFocus = { true }
        controller.setOverlayPresented(false, transition: .hover, reduceMotion: false)
        #expect(!recorder.recordedAccessibilityHidden)
        #expect(driver.requestCount == 1)

        controller.hasActiveSidebarAccessibilityFocus = { false }
        controller.setOverlayPresented(false, transition: .hover, reduceMotion: false)
        #expect(recorder.recordedAccessibilityHidden)
        #expect(driver.requestCount == 2)
    }

    @Test("persistent handoff preserves focused AX descendant identity and ancestry")
    func persistentHandoffPreservesAccessibilityDescendant() {
        let (controller, sidebar, _) = makeController()
        let descendant = NSView()
        sidebar.view.addSubview(descendant)
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        controller.setOverlayPresentedImmediately(true)
        let identity = ObjectIdentifier(descendant)
        controller.sidebarAccessibilityFocusedElement = { descendant }

        controller.setPersistentSidebarVisible(true)

        #expect(ObjectIdentifier(descendant) == identity)
        #expect(descendant.isDescendant(of: sidebar.view))
        // INT-845: the sidebar never moves, so the focused descendant's identity and
        // ancestry are preserved intrinsically (no capture/validate flag anymore).
        #expect(sidebar.view.superview === controller.sidebarHostViewForTesting)
        #expect((sidebar.view as? AccessibilityRecordingView)?.recordedAccessibilityHidden == false)
    }

    @Test("detach is idempotent, invalidates stale completion, and stays idle after reattach")
    func detachAndReattachLifecycle() {
        let driver = AnimationDriver()
        let (controller, sidebar, _) = makeControlledController(driver: driver)
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        controller.setOverlayPresented(true, transition: .hover, reduceMotion: false)
        let staleCompletion = driver.completions[0]
        #expect(controller.interactionObserverCountForTesting == 4)

        controller.settleDetached()
        controller.settleDetached()
        staleCompletion()

        #expect(controller.interactionObserverCountForTesting == 0)
        #expect(controller.hostModeForTesting == .hidden)
        #expect(sidebar.view.superview === controller.sidebarHostViewForTesting)
        #expect(controller.sidebarHostClipViewForTesting.isHidden)
        #expect(controller.sidebarHostViewForTesting.layer?.transform.m41 == 0)
        controller.viewWillAppear()
        controller.viewWillAppear()
        #expect(controller.interactionObserverCountForTesting == 0)
    }

    @Test("focused sidebar control and attributed menu retain until interaction ends")
    func focusedControlAndMenuRetention() {
        let (controller, sidebar, _) = makeController()
        let focus = FirstResponderView()
        sidebar.view.addSubview(focus)
        let window = NSWindow(
            contentRect: controller.view.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        controller.setOverlayPresentedImmediately(true)
        var changes: [Bool] = []
        controller.onSidebarInteractionChanged = { changes.append($0) }
        #expect(window.makeFirstResponder(focus))

        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        controller.sidebarPointerChanged(true)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        controller.sidebarPointerChanged(false)
        #expect(changes == [true])

        window.makeFirstResponder(nil)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)
        #expect(changes == [true, false])
    }

    @Test("keyboard menu and live AX retention flow through grace to overlay removal")
    func interactionEndToEndRemoval() async throws {
        let suiteName = "SidebarPresentationBehaviorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SidebarPresentationPreferenceStore(defaults: defaults)
        store.saveHidden(true)
        let gate = TestScheduler()
        let model = SidebarPresentationModel(store: store, delay: { await gate.wait(for: $0) })
        let center = NotificationCenter()
        let sidebar = NSViewController()
        sidebar.view = AccessibilityRecordingView()
        let focus = FirstResponderView()
        let axElement = NSView()
        sidebar.view.addSubview(focus)
        sidebar.view.addSubview(axElement)
        var focusedAX: Any?
        let detail = NSViewController()
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: detail,
            interactionFocusedAccessibilityElement: { focusedAX },
            interactionNotificationCenter: center)
        controller.onSidebarInteractionChanged = model.sidebarInteractionChanged
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let window = NSWindow(
            contentRect: controller.view.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        model.pointerMoved(x: 15, width: 100, position: .left)
        controller.setOverlayPresentedImmediately(true)
        focusedAX = axElement
        #expect(window.makeFirstResponder(focus))
        center.post(name: NSWindow.didUpdateNotification, object: window)
        controller.sidebarPointerChanged(true)
        center.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        controller.sidebarPointerChanged(false)
        model.sidebarPointerChanged(false)
        model.trackingRegionExited()

        window.makeFirstResponder(nil)
        center.post(name: NSWindow.didUpdateNotification, object: window)
        center.post(name: NSMenu.didEndTrackingNotification, object: nil)
        #expect(model.isTemporarilyRevealed)
        controller.setOverlayPresentedImmediately(false)
        #expect(controller.hostModeForTesting == .overlay(width: 300))

        focusedAX = nil
        center.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(await waitUntil { gate.sleeperCount == 1 })
        gate.advance()
        #expect(await waitUntil { !model.isSidebarVisible })
        controller.setOverlayPresentedImmediately(false)

        #expect(controller.hostModeForTesting == .hidden)
        #expect(sidebar.view.superview === controller.sidebarHostViewForTesting)
    }

    @Test(
        "application resignation clears transient presentation, peek, and gates pointer publication",
        arguments: [AppearanceConfig.SidebarPosition.left, .right]
    )
    func applicationResignationInvalidatesTransientPresentation(
        position: AppearanceConfig.SidebarPosition
    ) throws {
        let suiteName = "SidebarPresentationBehaviorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SidebarPresentationPreferenceStore(defaults: defaults)
        store.saveHidden(true)
        let model = SidebarPresentationModel(store: store)
        let peek = SidebarPeekModel()
        peek.onPointerChanged = model.peekPointerChanged
        let center = NotificationCenter()
        let sidebar = NSViewController()
        sidebar.view = AccessibilityRecordingView()
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: NSViewController(),
            interactionNotificationCenter: center,
            applicationIsActive: { true })
        controller.setSidebarPosition(position)
        let proxy = SidebarSplitProxy()
        controller.installCommandHandlers(on: proxy)
        controller.onEdgePointerMove = { x, width in
            model.pointerMoved(x: x, width: width, position: position)
            ContentView.reconcileSidebarOverlay(
                presentation: model,
                peekModel: peek,
                proxy: proxy,
                transition: .hover,
                reduceMotion: true)
        }
        controller.onTrackingAvailabilityLost = {
            model.invalidateTransientState()
            ContentView.reconcileSidebarOverlay(
                presentation: model,
                peekModel: peek,
                proxy: proxy,
                transition: .immediate,
                reduceMotion: true)
        }
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let window = NSWindow(
            contentRect: controller.view.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        let revealPoint = NSPoint(
            x: position == .left ? 15 : controller.view.bounds.maxX - 15,
            y: 100)

        controller.edgeTrackingViewForTesting.synchronizePointer(locationInWindow: revealPoint)
        #expect(model.proximityState == .revealed)
        #expect(controller.hostModeForTesting == .overlay(width: 300))
        let peekedSession = TestData.session(title: "Peeked", workingDirectory: "~")
        peek.show(
            session: peekedSession,
            location: .local("~"),
            tint: ProjectTint(groupName: "Group", color: nil, index: 0),
            frame: .zero,
            position: position)
        peek.setPointerOverCard(true, for: peekedSession.id)
        #expect(peek.session?.id == peekedSession.id)

        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)

        #expect(model.proximityState == .dormant)
        #expect(controller.hostModeForTesting == .hidden)
        #expect(peek.session == nil)

        controller.edgeTrackingViewForTesting.synchronizePointer(locationInWindow: revealPoint)
        #expect(model.proximityState == .dormant)
        #expect(controller.hostModeForTesting == .hidden)

        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        center.post(name: NSWindow.didResignKeyNotification, object: window)
        controller.edgeTrackingViewForTesting.synchronizePointer(locationInWindow: revealPoint)
        #expect(model.proximityState == .revealed)
        #expect(controller.hostModeForTesting == .overlay(width: 300))
    }

    @Test(
        "application resignation hides without moving focus until primary key readiness",
        arguments: [AppearanceConfig.SidebarPosition.left, .right]
    )
    func applicationResignationWaitsForPrimaryKeyReadiness(
        position: AppearanceConfig.SidebarPosition
    ) {
        var applicationIsActive = true
        let center = NotificationCenter()
        let sidebar = NSViewController()
        let sidebarFocus = FirstResponderView(
            frame: CGRect(x: 16, y: 720, width: 180, height: 24))
        sidebar.view.addSubview(sidebarFocus)
        let detail = NSViewController()
        let primaryContent = FirstResponderView(
            frame: CGRect(x: 20, y: 20, width: 120, height: 24))
        detail.view.addSubview(primaryContent)
        sidebarFocus.nextKeyView = primaryContent
        primaryContent.nextKeyView = sidebarFocus
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: detail,
            interactionNotificationCenter: center,
            applicationIsActive: { applicationIsActive })
        controller.setSidebarPosition(position)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let window = FocusReadinessWindow(
            contentRect: controller.view.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentViewController = controller
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        var requests: [SidebarFocusHandoffRequest] = []
        controller.onTrackingAvailabilityLost = { [weak controller] in
            controller?.setOverlayPresentedImmediately(false)
        }
        controller.setSidebarWidth(300)
        #expect(window.makeFirstResponder(primaryContent))
        controller.setSidebarHidden(true)
        #expect(controller.setOverlayPresentedImmediately(true))
        controller.onSidebarFocusHandoff = { request in
            requests.append(request)
            #expect(!request.requiresAccessibilityFocus)
            guard window.makeFirstResponder(primaryContent) else { return nil }
            return SidebarFocusHandoffOutcome(
                destination: primaryContent, satisfying: request)
        }
        #expect(window.makeFirstResponder(sidebarFocus))
        window.recordsMakeFirstResponder = true
        applicationIsActive = false

        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)

        #expect(controller.hostModeForTesting == .hidden)
        #expect(requests.isEmpty)
        #expect(window.recordedMakeFirstResponderCount == 1)
        #expect(window.firstResponder !== sidebarFocus)

        applicationIsActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        #expect(requests.isEmpty)
        #expect(window.recordedMakeFirstResponderCount == 1)

        window.reportsKey = true
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)

        #expect(
            requests
                == [
                    .init(
                        requiresKeyboardFocus: true,
                        requiresAccessibilityFocus: false)
                ])
        #expect(window.recordedMakeFirstResponderCount == 2)
        #expect(window.firstResponder === primaryContent)
    }

    @Test("key-first reactivation retries a pending focus repair on app activation")
    func keyFirstReactivationRetriesPendingRepairOnActivation() {
        var applicationIsActive = false
        let center = NotificationCenter()
        let fixture = ProductionFocusFixture(
            notificationCenter: center,
            applicationIsActive: { applicationIsActive })
        defer { fixture.cleanUp() }
        let selectedSurface = fixture.mountSelectedSurface()
        fixture.window.recordsMakeFirstResponder = true

        // Focus is in the sidebar with the app inactive but the primary window key.
        // Hiding now defers the repair (handoff isn't ready while the app is inactive).
        #expect(fixture.window.makeFirstResponder(fixture.sidebarFocus))
        fixture.window.reportsKey = true
        #expect(fixture.controller.setPersistentSidebarVisible(false))
        #expect(fixture.controller.hostModeForTesting == .hidden)
        #expect(fixture.window.firstResponder !== fixture.sidebarFocus)

        // Key-first ordering: `didBecomeKey` fires while the app is still inactive, so
        // the repair's app-active guard skips it — and no further `didBecomeKey` will
        // fire because the window is already key. Without the activation retry the
        // repair would be stranded here forever.
        center.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)
        #expect(fixture.window.firstResponder !== selectedSurface)

        // Activation with the window already key must retry the pending repair.
        applicationIsActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        #expect(fixture.window.firstResponder === selectedSurface)
    }

    @Test("application resignation cleans up when sidebar focus refuses to clear")
    func applicationResignationStillCleansUpWhenFocusRefusesToClear() {
        var applicationIsActive = true
        let center = NotificationCenter()
        let sidebar = NSViewController()
        let sidebarFocus = FirstResponderView(
            frame: CGRect(x: 16, y: 720, width: 180, height: 24))
        sidebar.view.addSubview(sidebarFocus)
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: NSViewController(),
            interactionNotificationCenter: center,
            applicationIsActive: { applicationIsActive })
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let window = FocusReadinessWindow(
            contentRect: controller.view.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentViewController = controller
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        var availabilityLossCount = 0
        controller.onTrackingAvailabilityLost = { [weak controller] in
            availabilityLossCount += 1
            controller?.setOverlayPresentedImmediately(false)
        }
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        #expect(controller.setOverlayPresentedImmediately(true))
        #expect(window.makeFirstResponder(sidebarFocus))
        window.refusesFirstResponderClear = true
        applicationIsActive = false

        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)

        #expect(availabilityLossCount == 1)
        #expect(controller.hostModeForTesting == .hidden)
        // INT-845: two refused clears now — the deliberate resignation clear, plus an
        // AppKit-induced resign when the permanent host is hidden while it still owns
        // the first responder. In production (no artificial refusal) both succeed and
        // focus correctly leaves the hidden sidebar; the cleanup still completes.
        #expect(window.refusedFirstResponderClearCount == 2)
    }

    @Test(
        "repeated resignation preserves unresolved hidden-sidebar focus for primary readiness",
        arguments: [
            RepeatedResignationCase(
                name: "keyboard only",
                requiresKeyboardFocus: true,
                requiresAccessibilityFocus: false,
                replacesAccessibilityElement: false),
            RepeatedResignationCase(
                name: "accessibility only",
                requiresKeyboardFocus: false,
                requiresAccessibilityFocus: true,
                replacesAccessibilityElement: false),
            RepeatedResignationCase(
                name: "keyboard and replacement accessibility element",
                requiresKeyboardFocus: true,
                requiresAccessibilityFocus: true,
                replacesAccessibilityElement: true),
        ])
    func repeatedResignationPreservesUnresolvedFocus(
        testCase: RepeatedResignationCase
    ) {
        var applicationIsActive = true
        let center = NotificationCenter()
        let sidebar = NSViewController()
        let sidebarKeyboardFocus = FirstResponderView(
            frame: CGRect(x: 16, y: 720, width: 180, height: 24))
        let originalSidebarAccessibilityFocus = AccessibilityFocusView(
            frame: CGRect(x: 16, y: 680, width: 180, height: 24))
        let replacementSidebarAccessibilityFocus = AccessibilityFocusView(
            frame: CGRect(x: 16, y: 640, width: 180, height: 24))
        sidebar.view.addSubview(sidebarKeyboardFocus)
        sidebar.view.addSubview(originalSidebarAccessibilityFocus)
        sidebar.view.addSubview(replacementSidebarAccessibilityFocus)
        let detail = NSViewController()
        let primaryFocus = AccessibilityFocusView(
            frame: CGRect(x: 20, y: 20, width: 180, height: 24))
        detail.view.addSubview(primaryFocus)
        var focusedAccessibilityElement: AccessibilityFocusView?
        for candidate in [
            originalSidebarAccessibilityFocus,
            replacementSidebarAccessibilityFocus,
            primaryFocus,
        ] {
            candidate.onFocusChange = { focused in
                if focused {
                    focusedAccessibilityElement = candidate
                } else if focusedAccessibilityElement === candidate {
                    focusedAccessibilityElement = nil
                }
            }
        }
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: detail,
            interactionFocusedAccessibilityElement: { focusedAccessibilityElement },
            interactionNotificationCenter: center,
            applicationIsActive: { applicationIsActive })
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let primaryWindow = FocusReadinessWindow(
            contentRect: controller.view.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        primaryWindow.contentViewController = controller
        primaryWindow.alphaValue = 0
        primaryWindow.orderFrontRegardless()
        let settingsFocus = FirstResponderView(
            frame: CGRect(x: 20, y: 20, width: 180, height: 24))
        let settingsWindow = FocusReadinessWindow(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        settingsWindow.contentView = settingsFocus
        settingsWindow.alphaValue = 0
        settingsWindow.orderFrontRegardless()
        defer {
            primaryWindow.orderOut(nil)
            settingsWindow.orderOut(nil)
        }
        controller.hasActiveSidebarAccessibilityFocus = {
            originalSidebarAccessibilityFocus.isAccessibilityFocused()
                || replacementSidebarAccessibilityFocus.isAccessibilityFocused()
        }
        controller.sidebarAccessibilityFocusedElement = { focusedAccessibilityElement }
        controller.onTrackingAvailabilityLost = { [weak controller] in
            controller?.setOverlayPresentedImmediately(false)
        }
        controller.setSidebarWidth(300)
        #expect(primaryWindow.makeFirstResponder(primaryFocus))
        controller.setSidebarHidden(true)
        #expect(controller.setOverlayPresentedImmediately(true))
        var requests: [SidebarFocusHandoffRequest] = []
        controller.onSidebarFocusHandoff = { request in
            requests.append(request)
            if request.requiresAccessibilityFocus {
                let savedSidebarElement =
                    testCase.replacesAccessibilityElement
                    ? replacementSidebarAccessibilityFocus
                    : originalSidebarAccessibilityFocus
                savedSidebarElement.setAccessibilityFocused(true)
                primaryFocus.setAccessibilityFocused(true)
            }
            if request.requiresKeyboardFocus {
                guard primaryWindow.makeFirstResponder(primaryFocus) else { return nil }
            }
            return SidebarFocusHandoffOutcome(
                destination: primaryFocus, satisfying: request)
        }
        if testCase.requiresKeyboardFocus {
            #expect(primaryWindow.makeFirstResponder(sidebarKeyboardFocus))
        }
        if testCase.requiresAccessibilityFocus {
            originalSidebarAccessibilityFocus.setAccessibilityFocused(true)
        }
        applicationIsActive = false

        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)

        #expect(requests.isEmpty)
        if testCase.requiresKeyboardFocus {
            #expect(primaryWindow.firstResponder !== sidebarKeyboardFocus)
        }
        if testCase.requiresAccessibilityFocus {
            originalSidebarAccessibilityFocus.setAccessibilityFocused(false)
        }
        applicationIsActive = true
        settingsWindow.reportsKey = true
        #expect(settingsWindow.makeFirstResponder(settingsFocus))
        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        center.post(name: NSWindow.didBecomeKeyNotification, object: settingsWindow)
        #expect(requests.isEmpty)

        if testCase.replacesAccessibilityElement {
            replacementSidebarAccessibilityFocus.setAccessibilityFocused(true)
        }
        applicationIsActive = false
        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(requests.isEmpty)

        applicationIsActive = true
        primaryWindow.reportsKey = false
        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        #expect(requests.isEmpty)
        settingsWindow.reportsKey = false
        primaryWindow.reportsKey = true
        center.post(name: NSWindow.didBecomeKeyNotification, object: primaryWindow)

        #expect(
            requests
                == [
                    .init(
                        requiresKeyboardFocus: testCase.requiresKeyboardFocus,
                        requiresAccessibilityFocus: testCase.requiresAccessibilityFocus)
                ])
        if testCase.requiresKeyboardFocus {
            #expect(primaryWindow.firstResponder === primaryFocus)
        }
        if testCase.requiresAccessibilityFocus {
            #expect(primaryFocus.isAccessibilityFocused())
            #expect(!originalSidebarAccessibilityFocus.isAccessibilityFocused())
            #expect(!replacementSidebarAccessibilityFocus.isAccessibilityFocused())
        }
        #expect(settingsWindow.firstResponder === settingsFocus)
    }

    @Test("repeated resignation does not resurrect an independently resolved modality")
    func repeatedResignationPreservesResolvedModality() {
        var applicationIsActive = true
        let center = NotificationCenter()
        let sidebar = NSViewController()
        let sidebarKeyboardFocus = FirstResponderView(
            frame: CGRect(x: 16, y: 720, width: 180, height: 24))
        let sidebarAccessibilityFocus = AccessibilityFocusView(
            frame: CGRect(x: 16, y: 680, width: 180, height: 24))
        sidebar.view.addSubview(sidebarKeyboardFocus)
        sidebar.view.addSubview(sidebarAccessibilityFocus)
        let detail = NSViewController()
        let primaryFocus = AccessibilityFocusView(
            frame: CGRect(x: 20, y: 20, width: 180, height: 24))
        detail.view.addSubview(primaryFocus)
        var focusedAccessibilityElement: AccessibilityFocusView?
        sidebarAccessibilityFocus.onFocusChange = { focused in
            focusedAccessibilityElement = focused ? sidebarAccessibilityFocus : nil
        }
        primaryFocus.onFocusChange = { focused in
            focusedAccessibilityElement = focused ? primaryFocus : nil
        }
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: detail,
            interactionFocusedAccessibilityElement: { focusedAccessibilityElement },
            interactionNotificationCenter: center,
            applicationIsActive: { applicationIsActive })
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let primaryWindow = FocusReadinessWindow(
            contentRect: controller.view.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        primaryWindow.contentViewController = controller
        primaryWindow.alphaValue = 0
        primaryWindow.orderFrontRegardless()
        let settingsWindow = FocusReadinessWindow(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        settingsWindow.contentView = FirstResponderView()
        settingsWindow.alphaValue = 0
        settingsWindow.orderFrontRegardless()
        defer {
            primaryWindow.orderOut(nil)
            settingsWindow.orderOut(nil)
        }
        controller.hasActiveSidebarAccessibilityFocus = {
            sidebarAccessibilityFocus.isAccessibilityFocused()
        }
        controller.sidebarAccessibilityFocusedElement = { focusedAccessibilityElement }
        controller.onTrackingAvailabilityLost = { [weak controller] in
            controller?.setOverlayPresentedImmediately(false)
        }
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        #expect(controller.setOverlayPresentedImmediately(true))
        #expect(primaryWindow.makeFirstResponder(sidebarKeyboardFocus))
        sidebarAccessibilityFocus.setAccessibilityFocused(true)
        var requests: [SidebarFocusHandoffRequest] = []
        var keyboardAttemptCount = 0
        controller.onSidebarFocusHandoff = { request in
            requests.append(request)
            #expect(!request.requiresAccessibilityFocus)
            keyboardAttemptCount += 1
            guard keyboardAttemptCount > 1,
                primaryWindow.makeFirstResponder(primaryFocus)
            else { return nil }
            return SidebarFocusHandoffOutcome(
                destination: primaryFocus, satisfying: request)
        }
        applicationIsActive = false
        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        sidebarAccessibilityFocus.setAccessibilityFocused(false)

        applicationIsActive = true
        primaryFocus.setAccessibilityFocused(true)
        primaryWindow.reportsKey = true
        center.post(name: NSWindow.didBecomeKeyNotification, object: primaryWindow)
        let keyboardOnlyRequest = SidebarFocusHandoffRequest(
            requiresKeyboardFocus: true,
            requiresAccessibilityFocus: false)
        #expect(requests == [keyboardOnlyRequest])

        primaryWindow.reportsKey = false
        settingsWindow.reportsKey = true
        applicationIsActive = false
        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)

        applicationIsActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        #expect(requests == [keyboardOnlyRequest])
        settingsWindow.reportsKey = false
        primaryWindow.reportsKey = true
        center.post(name: NSWindow.didBecomeKeyNotification, object: primaryWindow)

        #expect(requests == [keyboardOnlyRequest, keyboardOnlyRequest])
        #expect(primaryWindow.firstResponder === primaryFocus)
        #expect(primaryFocus.isAccessibilityFocused())
    }

    @Test("primary key readiness completes pending keyboard and accessibility recovery")
    func primaryKeyReadinessCompletesPendingCombinedRecovery() {
        var applicationIsActive = true
        let center = NotificationCenter()
        let sidebar = NSViewController()
        let sidebarKeyboardFocus = FirstResponderView(
            frame: CGRect(x: 16, y: 720, width: 180, height: 24))
        sidebar.view.addSubview(sidebarKeyboardFocus)
        let sidebarAccessibilityFocus = AccessibilityFocusView(
            frame: CGRect(x: 16, y: 680, width: 120, height: 24))
        sidebar.view.addSubview(sidebarAccessibilityFocus)
        let detail = NSViewController()
        let primaryContent = AccessibilityFocusView(
            frame: CGRect(x: 20, y: 20, width: 120, height: 24))
        detail.view.addSubview(primaryContent)
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: detail,
            interactionNotificationCenter: center,
            applicationIsActive: { applicationIsActive })
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let window = FocusReadinessWindow(
            contentRect: controller.view.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentViewController = controller
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        var requests: [SidebarFocusHandoffRequest] = []
        controller.hasActiveSidebarAccessibilityFocus = {
            sidebarAccessibilityFocus.isAccessibilityFocused()
        }
        controller.sidebarAccessibilityFocusedElement = { sidebarAccessibilityFocus }
        controller.onTrackingAvailabilityLost = { [weak controller] in
            controller?.setOverlayPresentedImmediately(false)
        }
        controller.setSidebarWidth(300)
        #expect(window.makeFirstResponder(primaryContent))
        controller.setSidebarHidden(true)
        #expect(controller.setOverlayPresentedImmediately(true))
        controller.onSidebarFocusHandoff = { request in
            requests.append(request)
            sidebarAccessibilityFocus.setAccessibilityFocused(false)
            primaryContent.setAccessibilityFocused(true)
            guard window.makeFirstResponder(primaryContent),
                primaryContent.isAccessibilityFocused()
            else { return nil }
            return SidebarFocusHandoffOutcome(
                destination: primaryContent, satisfying: request)
        }
        sidebarAccessibilityFocus.setAccessibilityFocused(true)
        #expect(window.makeFirstResponder(sidebarKeyboardFocus))
        applicationIsActive = false

        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)

        #expect(controller.hostModeForTesting == .hidden)
        #expect(requests.isEmpty)

        applicationIsActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        #expect(requests.isEmpty)

        window.reportsKey = true
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)

        #expect(window.firstResponder === primaryContent)
        #expect(primaryContent.isAccessibilityFocused())
        #expect(
            requests
                == [
                    .init(
                        requiresKeyboardFocus: true,
                        requiresAccessibilityFocus: true)
                ])
    }

    @Test("primary key readiness preserves AX-only recovery")
    func primaryKeyReadinessCompletesPendingAccessibilityOnlyRecovery() {
        var applicationIsActive = true
        let center = NotificationCenter()
        let sidebar = NSViewController()
        let sidebarAccessibilityFocus = AccessibilityFocusView(
            frame: CGRect(x: 16, y: 680, width: 120, height: 24))
        sidebar.view.addSubview(sidebarAccessibilityFocus)
        let detail = NSViewController()
        let detailKeyboardFocus = FirstResponderView(
            frame: CGRect(x: 20, y: 20, width: 120, height: 24))
        let detailAccessibilityFocus = AccessibilityFocusView(
            frame: CGRect(x: 20, y: 60, width: 120, height: 24))
        detail.view.addSubview(detailKeyboardFocus)
        detail.view.addSubview(detailAccessibilityFocus)
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: detail,
            interactionNotificationCenter: center,
            applicationIsActive: { applicationIsActive })
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let window = FocusReadinessWindow(
            contentRect: controller.view.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentViewController = controller
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        controller.hasActiveSidebarAccessibilityFocus = {
            sidebarAccessibilityFocus.isAccessibilityFocused()
        }
        controller.sidebarAccessibilityFocusedElement = { sidebarAccessibilityFocus }
        var requests: [SidebarFocusHandoffRequest] = []
        controller.onTrackingAvailabilityLost = { [weak controller] in
            controller?.setOverlayPresentedImmediately(false)
        }
        controller.setSidebarWidth(300)
        #expect(window.makeFirstResponder(detailKeyboardFocus))
        controller.setSidebarHidden(true)
        #expect(controller.setOverlayPresentedImmediately(true))
        controller.onSidebarFocusHandoff = { request in
            requests.append(request)
            sidebarAccessibilityFocus.setAccessibilityFocused(false)
            detailAccessibilityFocus.setAccessibilityFocused(true)
            guard detailAccessibilityFocus.isAccessibilityFocused() else { return nil }
            return SidebarFocusHandoffOutcome(
                destination: detailAccessibilityFocus, satisfying: request)
        }
        sidebarAccessibilityFocus.setAccessibilityFocused(true)
        applicationIsActive = false

        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(requests.isEmpty)

        applicationIsActive = true
        window.reportsKey = true
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)

        #expect(
            requests
                == [
                    .init(
                        requiresKeyboardFocus: false,
                        requiresAccessibilityFocus: true)
                ])
        #expect(window.firstResponder === detailKeyboardFocus)
        #expect(detailAccessibilityFocus.isAccessibilityFocused())
    }

    @Test("deferred AX recovery ignores unrelated global focus when typed target is unfocused")
    func deferredAccessibilityRecoveryRejectsStaleCallbackSuccess() {
        var applicationIsActive = true
        let center = NotificationCenter()
        let focusedElement = AccessibilityElementBox()
        let sidebar = NSViewController()
        let sidebarAccessibilityFocus = AccessibilityFocusView(
            frame: CGRect(x: 16, y: 680, width: 120, height: 24))
        sidebar.view.addSubview(sidebarAccessibilityFocus)
        let detail = NSViewController()
        let detailKeyboardFocus = FirstResponderView(
            frame: CGRect(x: 20, y: 20, width: 120, height: 24))
        let unrelatedGlobalFocus = AccessibilityFocusView(
            frame: CGRect(x: 20, y: 60, width: 120, height: 24))
        detail.view.addSubview(detailKeyboardFocus)
        detail.view.addSubview(unrelatedGlobalFocus)
        sidebarAccessibilityFocus.onFocusChange = { focused in
            focusedElement.element = focused ? sidebarAccessibilityFocus : nil
        }
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: detail,
            interactionFocusedAccessibilityElement: { focusedElement.element },
            interactionNotificationCenter: center,
            applicationIsActive: { applicationIsActive })
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let window = FocusReadinessWindow(
            contentRect: controller.view.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentViewController = controller
        window.alphaValue = 0
        window.reportsKey = true
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        controller.hasActiveSidebarAccessibilityFocus = {
            sidebarAccessibilityFocus.isAccessibilityFocused()
        }
        controller.sidebarAccessibilityFocusedElement = { sidebarAccessibilityFocus }
        controller.onTrackingAvailabilityLost = { [weak controller] in
            controller?.setOverlayPresentedImmediately(false)
        }
        controller.setSidebarWidth(300)
        #expect(window.makeFirstResponder(detailKeyboardFocus))
        controller.setSidebarHidden(true)
        #expect(controller.setOverlayPresentedImmediately(true))
        var requests: [SidebarFocusHandoffRequest] = []
        controller.onSidebarFocusHandoff = { request in
            requests.append(request)
            unrelatedGlobalFocus.setAccessibilityFocused(true)
            focusedElement.element = unrelatedGlobalFocus
            return SidebarFocusHandoffOutcome(
                destination: detailKeyboardFocus, satisfying: request)
        }
        sidebarAccessibilityFocus.setAccessibilityFocused(true)
        applicationIsActive = false
        window.reportsKey = false

        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)

        #expect(controller.hostModeForTesting == .hidden)
        #expect(requests.isEmpty)
        applicationIsActive = true
        window.reportsKey = true
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)

        let request = SidebarFocusHandoffRequest(
            requiresKeyboardFocus: false,
            requiresAccessibilityFocus: true)
        #expect(requests == [request])
        #expect(sidebarAccessibilityFocus.isAccessibilityFocused())
        #expect(focusedElement.element as? NSView === unrelatedGlobalFocus)
        focusedElement.element = sidebarAccessibilityFocus

        center.post(name: NSWindow.didBecomeKeyNotification, object: window)

        #expect(requests == [request, request])
        #expect(sidebarAccessibilityFocus.isAccessibilityFocused())
    }

    @Test("valid Settings focus preserves primary-owned application recovery")
    func settingsFocusPreservesPrimaryOwnedApplicationRecovery() {
        var applicationIsActive = true
        let center = NotificationCenter()
        let sidebar = NSViewController()
        let sidebarFocus = FirstResponderView(
            frame: CGRect(x: 16, y: 720, width: 180, height: 24))
        sidebar.view.addSubview(sidebarFocus)
        let detail = NSViewController()
        let primarySafeFocus = FirstResponderView(
            frame: CGRect(x: 20, y: 20, width: 180, height: 24))
        detail.view.addSubview(primarySafeFocus)
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: detail,
            interactionNotificationCenter: center,
            applicationIsActive: { applicationIsActive })
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let primaryWindow = FocusReadinessWindow(
            contentRect: controller.view.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        primaryWindow.contentViewController = controller
        primaryWindow.alphaValue = 0
        primaryWindow.orderFrontRegardless()
        let settingsFocus = FirstResponderView(
            frame: CGRect(x: 20, y: 20, width: 180, height: 24))
        let settingsWindow = FocusReadinessWindow(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        settingsWindow.contentView = settingsFocus
        settingsWindow.alphaValue = 0
        settingsWindow.orderFrontRegardless()
        defer {
            primaryWindow.orderOut(nil)
            settingsWindow.orderOut(nil)
        }
        var requests: [SidebarFocusHandoffRequest] = []
        controller.onTrackingAvailabilityLost = { [weak controller] in
            controller?.setOverlayPresentedImmediately(false)
        }
        controller.setSidebarWidth(300)
        #expect(primaryWindow.makeFirstResponder(primarySafeFocus))
        controller.setSidebarHidden(true)
        #expect(controller.setOverlayPresentedImmediately(true))
        controller.onSidebarFocusHandoff = { request in
            requests.append(request)
            guard primaryWindow.makeFirstResponder(primarySafeFocus) else { return nil }
            return SidebarFocusHandoffOutcome(
                destination: primarySafeFocus, satisfying: request)
        }
        #expect(primaryWindow.makeFirstResponder(sidebarFocus))
        applicationIsActive = false

        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(controller.hostModeForTesting == .hidden)
        #expect(requests.isEmpty)

        applicationIsActive = true
        // Activation now retries a pending repair (INT-845 key-first ordering fix),
        // but the retry re-checks every precondition: the primary window is not key
        // yet, so the repair still correctly defers and no handoff fires.
        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        #expect(requests.isEmpty)

        settingsWindow.reportsKey = true
        #expect(settingsWindow.makeFirstResponder(settingsFocus))
        center.post(name: NSWindow.didBecomeKeyNotification, object: settingsWindow)
        primaryWindow.reportsKey = true
        center.post(name: NSWindow.didBecomeKeyNotification, object: primaryWindow)

        #expect(
            requests
                == [
                    .init(
                        requiresKeyboardFocus: true,
                        requiresAccessibilityFocus: false)
                ])
        #expect(primaryWindow.firstResponder === primarySafeFocus)
        #expect(settingsWindow.firstResponder === settingsFocus)
    }

    @Test(
        "Settings focus does not reduce primary recovery by modality",
        arguments: [
            RecoveryReductionCase(
                initialKeyboardFocus: false,
                movesKeyboardFocus: false,
                movesAccessibilityFocus: true),
            RecoveryReductionCase(
                initialKeyboardFocus: true,
                movesKeyboardFocus: false,
                movesAccessibilityFocus: true),
            RecoveryReductionCase(
                initialKeyboardFocus: true,
                movesKeyboardFocus: true,
                movesAccessibilityFocus: false),
        ])
    func settingsFocusDoesNotReducePrimaryRecoveryByModality(
        testCase: RecoveryReductionCase
    ) {
        var applicationIsActive = true
        let center = NotificationCenter()
        let sidebar = NSViewController()
        let sidebarKeyboardFocus = FirstResponderView(
            frame: CGRect(x: 16, y: 720, width: 180, height: 24))
        let sidebarAccessibilityFocus = AccessibilityFocusView(
            frame: CGRect(x: 16, y: 680, width: 180, height: 24))
        sidebar.view.addSubview(sidebarKeyboardFocus)
        sidebar.view.addSubview(sidebarAccessibilityFocus)
        let detail = NSViewController()
        let primaryFocus = AccessibilityFocusView(
            frame: CGRect(x: 20, y: 20, width: 180, height: 24))
        detail.view.addSubview(primaryFocus)
        var focusedAccessibilityElement: Any?
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: detail,
            interactionFocusedAccessibilityElement: { focusedAccessibilityElement },
            interactionNotificationCenter: center,
            applicationIsActive: { applicationIsActive })
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let primaryWindow = FocusReadinessWindow(
            contentRect: controller.view.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        primaryWindow.contentViewController = controller
        primaryWindow.alphaValue = 0
        primaryWindow.orderFrontRegardless()
        let settingsKeyboardFocus = FirstResponderView(
            frame: CGRect(x: 20, y: 20, width: 180, height: 24))
        let settingsAccessibilityFocus = AccessibilityFocusView(
            frame: CGRect(x: 20, y: 60, width: 180, height: 24))
        let settingsContent = NSView(
            frame: CGRect(x: 0, y: 0, width: 480, height: 320))
        settingsContent.addSubview(settingsKeyboardFocus)
        settingsContent.addSubview(settingsAccessibilityFocus)
        let settingsWindow = FocusReadinessWindow(
            contentRect: settingsContent.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        settingsWindow.contentView = settingsContent
        settingsWindow.alphaValue = 0
        settingsWindow.orderFrontRegardless()
        defer {
            primaryWindow.orderOut(nil)
            settingsWindow.orderOut(nil)
        }
        controller.onTrackingAvailabilityLost = { [weak controller] in
            controller?.setOverlayPresentedImmediately(false)
        }
        controller.setSidebarWidth(300)
        #expect(primaryWindow.makeFirstResponder(primaryFocus))
        controller.setSidebarHidden(true)
        #expect(controller.setOverlayPresentedImmediately(true))
        var requests: [SidebarFocusHandoffRequest] = []
        controller.onSidebarFocusHandoff = { request in
            requests.append(request)
            if request.requiresAccessibilityFocus {
                focusedAccessibilityElement = primaryFocus
                primaryFocus.setAccessibilityFocused(true)
            }
            guard primaryWindow.makeFirstResponder(primaryFocus) else { return nil }
            return SidebarFocusHandoffOutcome(
                destination: primaryFocus, satisfying: request)
        }
        if testCase.initialKeyboardFocus {
            #expect(primaryWindow.makeFirstResponder(sidebarKeyboardFocus))
        }
        focusedAccessibilityElement = sidebarAccessibilityFocus
        sidebarAccessibilityFocus.setAccessibilityFocused(true)
        applicationIsActive = false

        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)

        #expect(controller.hostModeForTesting == .hidden)
        #expect(requests.isEmpty)
        applicationIsActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        if testCase.movesKeyboardFocus {
            #expect(settingsWindow.makeFirstResponder(settingsKeyboardFocus))
        } else {
            _ = settingsWindow.makeFirstResponder(nil)
        }
        if testCase.movesAccessibilityFocus {
            sidebarAccessibilityFocus.setAccessibilityFocused(false)
            focusedAccessibilityElement = settingsAccessibilityFocus
            settingsAccessibilityFocus.setAccessibilityFocused(true)
        }
        settingsWindow.reportsKey = true
        center.post(name: NSWindow.didBecomeKeyNotification, object: settingsWindow)
        settingsWindow.reportsKey = false
        primaryWindow.reportsKey = true
        center.post(name: NSWindow.didBecomeKeyNotification, object: primaryWindow)

        #expect(
            requests
                == [
                    .init(
                        requiresKeyboardFocus: testCase.initialKeyboardFocus,
                        requiresAccessibilityFocus: true)
                ])
        #expect(primaryWindow.firstResponder === primaryFocus)
        #expect(focusedAccessibilityElement as? NSView === primaryFocus)
        #expect(primaryFocus.isAccessibilityFocused())
    }

    @Test("detaching cancels failed resignation focus recovery before reattachment")
    func detachingCancelsFailedApplicationFocusRecovery() throws {
        let center = NotificationCenter()
        let sidebar = NSViewController()
        let sidebarFocus = AccessibilityFocusView(
            frame: CGRect(x: 16, y: 680, width: 120, height: 24))
        sidebar.view.addSubview(sidebarFocus)
        let detail = NSViewController()
        let currentFocus = FirstResponderView(
            frame: CGRect(x: 20, y: 20, width: 120, height: 24))
        let staleRecoveryTarget = FirstResponderView(
            frame: CGRect(x: 20, y: 60, width: 120, height: 24))
        detail.view.addSubview(currentFocus)
        detail.view.addSubview(staleRecoveryTarget)
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: detail,
            interactionNotificationCenter: center,
            applicationIsActive: { true })
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let window = NSWindow(
            contentRect: controller.view.bounds,
            styleMask: [],
            backing: .buffered,
            defer: false)
        window.contentViewController = controller
        var requests: [SidebarFocusHandoffRequest] = []
        controller.hasActiveSidebarAccessibilityFocus = {
            sidebarFocus.isAccessibilityFocused()
        }
        controller.sidebarAccessibilityFocusedElement = { sidebarFocus }
        controller.onSidebarFocusHandoff = { request in
            requests.append(request)
            return nil
        }
        controller.onTrackingAvailabilityLost = { [weak controller] in
            controller?.setOverlayPresentedImmediately(false)
        }
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        #expect(controller.setOverlayPresentedImmediately(true))
        sidebarFocus.setAccessibilityFocused(true)
        #expect(window.makeFirstResponder(sidebarFocus))

        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)

        #expect(requests.isEmpty)

        window.contentViewController = nil
        window.contentViewController = controller
        #expect(window.makeFirstResponder(currentFocus))
        controller.onSidebarFocusHandoff = { request in
            requests.append(request)
            guard window.makeFirstResponder(staleRecoveryTarget) else { return nil }
            return SidebarFocusHandoffOutcome(
                destination: staleRecoveryTarget, satisfying: request)
        }

        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)

        #expect(requests.isEmpty)
        #expect(window.firstResponder === currentFocus)
    }

    @Test("position change retains active interaction until ordinary grace dismissal")
    func positionChangeRetainsInteractionLifecycle() async throws {
        let suiteName = "SidebarPresentationBehaviorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SidebarPresentationPreferenceStore(defaults: defaults)
        store.saveHidden(true)
        let gate = TestScheduler()
        let model = SidebarPresentationModel(store: store, delay: { await gate.wait(for: $0) })
        let center = NotificationCenter()
        let sidebar = NSViewController()
        sidebar.view = AccessibilityRecordingView()
        let keyboardFocus = FirstResponderView()
        let accessibilityFocus = NSView()
        sidebar.view.addSubview(keyboardFocus)
        sidebar.view.addSubview(accessibilityFocus)
        var focusedAccessibilityElement: Any?
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: NSViewController(),
            interactionFocusedAccessibilityElement: { focusedAccessibilityElement },
            interactionNotificationCenter: center)
        controller.onSidebarInteractionChanged = model.sidebarInteractionChanged
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let window = NSWindow(
            contentRect: controller.view.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        model.pointerMoved(x: 15, width: 100, position: .left)
        controller.setOverlayPresentedImmediately(true)

        focusedAccessibilityElement = accessibilityFocus
        #expect(window.makeFirstResponder(keyboardFocus))
        center.post(name: NSWindow.didUpdateNotification, object: window)
        controller.sidebarPointerChanged(true)
        center.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        controller.sidebarPointerChanged(false)
        model.sidebarPointerChanged(false)
        model.trackingRegionExited()
        #expect(model.proximityState == .revealed)

        // Mirror ContentView.applySidebarPosition followed by its proximity observer.
        controller.setSidebarPosition(.right)
        model.positionDidChange()
        controller.setOverlayPresentedImmediately(model.proximityState == .revealed)

        #expect(model.proximityState == .revealed)
        #expect(controller.hostModeForTesting == .overlay(width: 300))
        #expect(controller.sidebarHostClipViewForTesting.frame.maxX == controller.view.bounds.maxX)
        #expect(gate.sleepCallCount == 0)

        window.makeFirstResponder(nil)
        center.post(name: NSWindow.didUpdateNotification, object: window)
        center.post(name: NSMenu.didEndTrackingNotification, object: nil)
        #expect(model.proximityState == .revealed)

        focusedAccessibilityElement = nil
        center.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(await waitUntil { gate.sleeperCount == 1 })
        gate.advance()
        #expect(await waitUntil { model.proximityState == .dormant })
        controller.setOverlayPresentedImmediately(model.proximityState == .revealed)

        #expect(controller.hostModeForTesting == .hidden)
        #expect(sidebar.view.superview === controller.sidebarHostViewForTesting)
    }

    @Test("explicit hide clears stale sidebar pointer attribution before another menu begins")
    func explicitHideClearsPointerAttribution() throws {
        let suiteName = "SidebarPresentationBehaviorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SidebarPresentationPreferenceStore(defaults: defaults)
        store.saveHidden(false)
        let model = SidebarPresentationModel(store: store)
        let center = NotificationCenter()
        let controller = SidebarSplitController(
            sidebar: NSViewController(),
            detail: NSViewController(),
            interactionNotificationCenter: center)
        controller.onSidebarInteractionChanged = model.sidebarInteractionChanged
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let window = NSWindow(
            contentRect: controller.view.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.setSidebarWidth(300)
        controller.sidebarPointerChanged(true)

        #expect(
            model.applyPersistentHidden(true) { visible in
                controller.deliverPersistentSidebarVisible(visible)
            } == .applied)
        #expect(model.proximityState == .dormant)
        #expect(controller.hostModeForTesting == .hidden)

        center.post(name: NSMenu.didBeginTrackingNotification, object: nil)

        #expect(model.proximityState == .dormant)
        #expect(controller.hostModeForTesting == .hidden)
    }

    @Test("stable hidden reconciliation clears stale sidebar pointer attribution")
    func stableHiddenReconciliationClearsPointerAttribution() throws {
        let suiteName = "SidebarPresentationBehaviorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SidebarPresentationPreferenceStore(defaults: defaults)
        store.saveHidden(true)
        let model = SidebarPresentationModel(store: store)
        let center = NotificationCenter()
        let controller = SidebarSplitController(
            sidebar: NSViewController(),
            detail: NSViewController(),
            interactionNotificationCenter: center)
        controller.onSidebarInteractionChanged = model.sidebarInteractionChanged
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let window = NSWindow(
            contentRect: controller.view.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.setSidebarWidth(300)
        #expect(controller.setPersistentSidebarVisible(false))
        model.pointerMoved(x: 15, width: 100, position: .left)
        controller.setOverlayPresentedImmediately(true)
        controller.sidebarPointerChanged(true)

        model.invalidateTransientState()
        controller.setOverlayPresentedImmediately(false)
        #expect(model.proximityState == .dormant)
        #expect(controller.hostModeForTesting == .hidden)

        center.post(name: NSMenu.didBeginTrackingNotification, object: nil)

        #expect(model.proximityState == .dormant)
        #expect(controller.hostModeForTesting == .hidden)
    }

    @Test("live AX retention repairs a missed monitor poll and later dismisses through grace")
    func liveAccessibilityRetentionRepairsMonitorLatch() async throws {
        let suiteName = "SidebarPresentationBehaviorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SidebarPresentationPreferenceStore(defaults: defaults)
        store.saveHidden(true)
        let gate = TestScheduler()
        let model = SidebarPresentationModel(store: store, delay: { await gate.wait(for: $0) })
        let center = NotificationCenter()
        let sidebar = NSViewController()
        sidebar.view = AccessibilityRecordingView()
        let accessibilityFocus = NSView()
        sidebar.view.addSubview(accessibilityFocus)
        var focusedAccessibilityElement: Any?
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: NSViewController(),
            interactionFocusedAccessibilityElement: { focusedAccessibilityElement },
            interactionNotificationCenter: center)
        controller.onSidebarInteractionChanged = model.sidebarInteractionChanged
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let window = NSWindow(
            contentRect: controller.view.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        model.pointerMoved(x: 15, width: 100, position: .left)
        controller.setOverlayPresentedImmediately(true)

        // The focus source changes without a window update, so the monitor's
        // published latch is intentionally stale when the model goes dormant.
        focusedAccessibilityElement = accessibilityFocus
        model.positionDidChange()
        #expect(model.proximityState == .dormant)
        controller.setOverlayPresentedImmediately(false)

        #expect(controller.hostModeForTesting == .overlay(width: 300))
        #expect(model.proximityState == .revealed)

        focusedAccessibilityElement = nil
        center.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(await waitUntil { gate.sleeperCount == 1 })
        gate.advance()
        #expect(await waitUntil { model.proximityState == .dormant })
        controller.setOverlayPresentedImmediately(false)

        #expect(controller.hostModeForTesting == .hidden)
        #expect(sidebar.view.superview === controller.sidebarHostViewForTesting)
    }

    @Test("hide reconciliation retains a keyboard interaction missed before window update")
    func hideReconciliationRetainsMissedKeyboardInteraction() async throws {
        let suiteName = "SidebarPresentationBehaviorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SidebarPresentationPreferenceStore(defaults: defaults)
        store.saveHidden(true)
        let gate = TestScheduler()
        let model = SidebarPresentationModel(store: store, delay: { await gate.wait(for: $0) })
        let sidebar = NSViewController()
        sidebar.view = AccessibilityRecordingView()
        let focus = FirstResponderView()
        sidebar.view.addSubview(focus)
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: NSViewController(),
            applicationIsActive: { true })
        controller.onSidebarInteractionChanged = model.sidebarInteractionChanged
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let window = NSWindow(
            contentRect: controller.view.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        model.pointerMoved(x: 15, width: 100, position: .left)
        controller.setOverlayPresentedImmediately(true)

        model.trackingRegionExited()
        #expect(await waitUntil { gate.sleeperCount == 1 })
        #expect(window.makeFirstResponder(focus))
        gate.advance()
        #expect(await waitUntil { model.proximityState == .dormant })

        controller.setOverlayPresentedImmediately(false)

        #expect(model.proximityState == .revealed)
        #expect(controller.hostModeForTesting == .overlay(width: 300))
        #expect(sidebar.view.superview === controller.sidebarHostViewForTesting)
    }

    @Test("drag clear resamples stale tracker state before publishing sidebar containment")
    func dragClearResamplesTrackerBeforeContainment() async throws {
        let suiteName = "SidebarPresentationBehaviorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SidebarPresentationPreferenceStore(defaults: defaults)
        store.saveHidden(true)
        let gate = TestScheduler()
        let model = SidebarPresentationModel(store: store, delay: { await gate.wait(for: $0) })
        var currentScreenPoint = NSPoint.zero
        let sidebar = NSViewController()
        sidebar.view = AccessibilityRecordingView()
        let controller = SidebarSplitController(
            sidebar: sidebar,
            detail: NSViewController(),
            currentMouseLocation: { currentScreenPoint },
            applicationIsActive: { true })
        controller.onEdgePointerMove = { x, width in
            model.pointerMoved(x: x, width: width, position: .left)
        }
        controller.onEdgeExit = model.trackingRegionExited
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let window = NSWindow(
            contentRect: controller.view.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        controller.setOverlayPresentedImmediately(true)

        func beginDragFromReveal() {
            controller.edgeTrackingViewForTesting.synchronizePointer(
                locationInWindow: NSPoint(x: 15, y: 100))
            model.sidebarPointerChanged(true)
            #expect(model.proximityState == .revealed)
        }

        beginDragFromReveal()
        currentScreenPoint = window.convertPoint(
            toScreen: NSPoint(x: controller.view.bounds.midX, y: -20))
        let outsideSidebar = try #require(
            controller.resampleSidebarPointerForTesting() as Bool?)
        #expect(!outsideSidebar)
        model.sidebarPointerChanged(outsideSidebar)
        #expect(await waitUntil { gate.sleeperCount == 1 })
        gate.advanceOneCycle()
        #expect(await waitUntil { model.proximityState == .dormant })

        beginDragFromReveal()
        currentScreenPoint = window.convertPoint(toScreen: NSPoint(x: 350, y: 100))
        let insideAttractionField = try #require(
            controller.resampleSidebarPointerForTesting() as Bool?)
        #expect(!insideAttractionField)
        model.sidebarPointerChanged(insideAttractionField)
        #expect(await waitUntil { gate.sleeperCount == 1 })
        gate.advanceOneCycle()
        #expect(await waitUntil { model.proximityState == .cue })

        beginDragFromReveal()
        currentScreenPoint = window.convertPoint(toScreen: NSPoint(x: 100, y: 100))
        let insideSidebar = try #require(
            controller.resampleSidebarPointerForTesting() as Bool?)
        #expect(insideSidebar)
        model.sidebarPointerChanged(insideSidebar)
        #expect(model.proximityState == .revealed)
        #expect(gate.sleeperCount == 0)
    }

    @Test("active interaction reports false exactly once across repeated lifecycle teardown")
    func teardownReportsFalseOnce() {
        let (controller, sidebar, _) = makeController()
        let focus = FirstResponderView()
        sidebar.view.addSubview(focus)
        let window = NSWindow(
            contentRect: controller.view.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = controller.view
        var changes: [Bool] = []
        controller.onSidebarInteractionChanged = { changes.append($0) }
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        controller.setOverlayPresentedImmediately(true)
        #expect(window.makeFirstResponder(focus))
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)

        controller.viewWillDisappear()
        controller.viewDidDisappear()

        #expect(changes == [true, false])
        #expect(controller.interactionObserverCountForTesting == 0)
    }

    @Test("detached controller releases after outward callbacks are cleared")
    func detachedControllerDeallocates() {
        weak var weakController: SidebarSplitController?
        weak var weakToken: LifetimeToken?
        autoreleasepool {
            let (controller, _, _) = makeController()
            weakController = controller
            let token = LifetimeToken()
            weakToken = token
            controller.onLiveWidthChange = { _ in _ = token }
            controller.onSidebarInteractionChanged = { _ in _ = token }
            controller.settleDetached()
            #expect(weakToken != nil)
        }
        #expect(weakController == nil)
        #expect(weakToken == nil)
    }

    @Test("representable dismantle releases never-loaded self-capturing controller")
    func neverLoadedDismantleDeallocates() {
        weak var weakController: SidebarSplitController?
        autoreleasepool {
            let controller = SidebarSplitController(
                sidebar: NSViewController(), detail: NSViewController())
            weakController = controller
            controller.onLiveWidthChange = { [controller] _ in _ = controller }
            controller.onSidebarInteractionChanged = { [controller] _ in _ = controller }

            SidebarSplitView<EmptyView, EmptyView>.dismantleNSViewController(
                controller, coordinator: ())
            #expect(controller.isFinalizedForTesting)
        }
        #expect(weakController == nil)
    }

    @Test("deinit reports active interaction false and releases controller")
    func activeControllerDeinitCleansInteraction() {
        weak var weakController: SidebarSplitController?
        var changes: [Bool] = []
        autoreleasepool {
            let (controller, sidebar, _) = makeController()
            weakController = controller
            let focus = FirstResponderView()
            sidebar.view.addSubview(focus)
            let window = NSWindow(
                contentRect: controller.view.bounds, styleMask: [], backing: .buffered,
                defer: false)
            window.contentView = controller.view
            controller.onSidebarInteractionChanged = { changes.append($0) }
            controller.setSidebarWidth(300)
            controller.setSidebarHidden(true)
            controller.setOverlayPresentedImmediately(true)
            #expect(window.makeFirstResponder(focus))
            NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
            #expect(changes == [true])
        }
        #expect(weakController == nil)
        #expect(changes == [true, false])
    }

    @Test("side change collapses a passive in-flight reveal")
    func sideChangeCollapsesPassiveReveal() {
        let driver = AnimationDriver()
        let (controller, sidebar, _) = makeControlledController(driver: driver)
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        controller.setOverlayPresented(true, transition: .hover, reduceMotion: false)
        let staleCompletion = driver.completions[0]

        controller.setSidebarPosition(.right)
        staleCompletion()

        #expect(controller.hostModeForTesting == .hidden)
        #expect(sidebar.view.superview === controller.sidebarHostViewForTesting)
        #expect(controller.sidebarHostViewForTesting.layer?.transform.m41 == 0)
        #expect(controller.hostPresentationState.mode == .hidden)
        #expect(controller.hostPresentationState.effectiveVisibleWidth == 0)
        #expect(controller.sidebarHostClipViewForTesting.isHidden)
        #expect(driver.requestCount == 1)
    }

    @Test("side change keeps an in-flight hide stably hidden after stale completion")
    func sideChangeKeepsInFlightHideHidden() {
        let driver = AnimationDriver()
        let (controller, sidebar, _) = makeControlledController(driver: driver)
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        controller.setOverlayPresented(true, transition: .hover, reduceMotion: false)
        driver.completions[0]()
        controller.setOverlayPresented(false, transition: .hover, reduceMotion: false)
        let staleHideCompletion = driver.completions[1]

        controller.setSidebarPosition(.right)
        staleHideCompletion()

        #expect(controller.hostModeForTesting == .hidden)
        #expect(controller.hostPresentationState.mode == .hidden)
        #expect(sidebar.view.superview === controller.sidebarHostViewForTesting)
        #expect(controller.sidebarHostClipViewForTesting.isHidden)
        #expect(controller.sidebarHostViewForTesting.layer?.transform.m41 == 0)
    }

    @Test("reasserting hidden dismisses a presented overlay into stable hidden ownership")
    func repeatedHiddenDismissesOverlay() {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        controller.setOverlayPresentedImmediately(true)

        controller.setSidebarHidden(true)

        #expect(controller.hostModeForTesting == .hidden)
        #expect(sidebar.view.superview === controller.sidebarHostViewForTesting)
        #expect(controller.sidebarHostClipViewForTesting.isHidden)
        #expect((sidebar.view as? AccessibilityRecordingView)?.recordedAccessibilityHidden == true)
    }

    @Test("overlay presentation fails closed when content layer is unavailable")
    func missingLayerFailsClosed() {
        let (controller, sidebar, _) = makeController()
        controller.setSidebarWidth(300)
        controller.setSidebarHidden(true)
        controller.sidebarHostViewForTesting.wantsLayer = false
        controller.sidebarHostViewForTesting.layer = nil

        controller.setOverlayPresentedImmediately(true)

        #expect(controller.hostModeForTesting == .hidden)
        #expect(sidebar.view.superview === controller.sidebarHostViewForTesting)
        #expect(controller.sidebarHostClipViewForTesting.isHidden)
        #expect((sidebar.view as? AccessibilityRecordingView)?.recordedAccessibilityHidden == true)
    }

    @Test(
        "root updates preserve the same sidebar host and presentation ownership",
        arguments: [UpdateMode.hidden, .overlay, .midAnimation, .persistent])
    func sameHostRootUpdate(mode: UpdateMode) throws {
        let sidebar = NSHostingController(rootView: RootFixture(value: "old"))
        let detail = NSViewController()
        let controller = SidebarSplitController(sidebar: sidebar, detail: detail)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        controller.setSidebarWidth(300)
        switch mode {
        case .hidden:
            controller.setSidebarHidden(true)
        case .overlay, .midAnimation:
            controller.setSidebarHidden(true)
            controller.setOverlayPresentedImmediately(true)
            if mode == .midAnimation {
                controller.sidebarHostViewForTesting.layer?.setAffineTransform(
                    CGAffineTransform(translationX: -150, y: 0))
            }
        case .persistent:
            break
        }
        let identity = ObjectIdentifier(controller.sidebarViewController)
        let parent = sidebar.view.superview
        let hostMode = controller.hostModeForTesting
        let paneViews = controller.splitPaneViewsForTesting
        let detailFrame = detail.view.frame

        // This is the operation performed by SidebarSplitView.updateNSViewController.
        sidebar.rootView = RootFixture(value: "new")

        #expect(ObjectIdentifier(controller.sidebarViewController) == identity)
        #expect(controller.sidebarHostOccurrenceCountForTesting == 1)
        #expect(sidebar.view.superview === parent)
        #expect(controller.hostModeForTesting == hostMode)
        #expect(controller.splitPaneViewsForTesting == paneViews)
        #expect(detail.view.frame == detailFrame)
        #expect(sidebar.rootView.value == "new")
    }

    private func waitUntil(_ condition: () -> Bool, attempts: Int = 10_000) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    // MARK: - Root-level hit testing (INT-845)

    /// Hosts the controller inside a window-backed container at a NON-ZERO origin so
    /// `controller.view.hitTest` runs against the superview-coordinate trap the
    /// permanent root-sibling host introduces. Returns the origin offset to add to a
    /// view-local point to reach the container coordinate space `hitTest` expects.
    private func hostAtNonZeroOrigin(
        _ controller: SidebarSplitController,
        origin: CGPoint = CGPoint(x: 213, y: 137)
    ) -> (window: NSWindow, offset: CGPoint) {
        let container = NSView(
            frame: CGRect(x: 0, y: 0, width: origin.x + 1_400, height: origin.y + 1_000))
        let window = NSWindow(
            contentRect: container.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = container
        controller.view.frame = CGRect(origin: origin, size: CGSize(width: 1_200, height: 800))
        container.addSubview(controller.view)
        controller.view.layoutSubtreeIfNeeded()
        return (window, origin)
    }

    @Test(
        "root hit testing routes sidebar body, divider, and terminal for both positions",
        arguments: [AppearanceConfig.SidebarPosition.left, .right])
    func rootHitTestingRoutesPanes(position: AppearanceConfig.SidebarPosition) {
        let (controller, sidebar, detail) = makeController(position: position)
        controller.setSidebarWidth(300)
        let (window, offset) = hostAtNonZeroOrigin(controller)
        defer { window.orderOut(nil) }

        let pane = controller.sidebarPaneFrameForTesting
        let detailFrame = detail.view.frame
        let thickness = controller.dividerThicknessForTesting
        #expect(thickness > 0)
        func rootPoint(x: CGFloat, y: CGFloat) -> NSPoint {
            NSPoint(x: x + offset.x, y: y + offset.y)
        }

        // 1. Sidebar body -> a sidebar descendant.
        let bodyHit = controller.view.hitTest(rootPoint(x: pane.midX, y: pane.midY))
        #expect(bodyHit === sidebar.view || bodyHit?.isDescendant(of: sidebar.view) == true)

        // 2. Divider center -> the split view's divider tracking, not the host container.
        let dividerX = position == .left ? pane.maxX + thickness / 2 : pane.minX - thickness / 2
        let dividerHit = controller.view.hitTest(rootPoint(x: dividerX, y: pane.midY))
        #expect(dividerHit === controller.splitViewForTesting)
        #expect(dividerHit?.isDescendant(of: sidebar.view) != true)

        // 3. Terminal-side of the divider -> the detail view. Clear NSSplitView's
        // expanded divider grab region (a few points past the thin divider) so the
        // point lands in the terminal pane, not the divider tracking.
        let terminalX = position == .left ? detailFrame.minX + 20 : detailFrame.maxX - 20
        let terminalHit = controller.view.hitTest(rootPoint(x: terminalX, y: detailFrame.midY))
        #expect(terminalHit === detail.view || terminalHit?.isDescendant(of: detail.view) == true)
    }

    @Test(
        "root hit testing never reaches a persistently hidden sidebar",
        arguments: [AppearanceConfig.SidebarPosition.left, .right])
    func rootHitTestingHiddenSidebarUnreachable(position: AppearanceConfig.SidebarPosition) {
        let (controller, sidebar, _) = makeController(position: position)
        controller.setSidebarWidth(300)
        #expect(controller.setPersistentSidebarVisible(false))
        let (window, offset) = hostAtNonZeroOrigin(controller)
        defer { window.orderOut(nil) }

        let width = controller.view.bounds.width
        let height = controller.view.bounds.height
        let sidebarEdge: CGFloat = position == .left ? 4 : width - 4
        for x in [sidebarEdge, width / 4, width / 2, 3 * width / 4] {
            let hit = controller.view.hitTest(NSPoint(x: x + offset.x, y: height / 2 + offset.y))
            #expect(hit !== sidebar.view)
            #expect(hit?.isDescendant(of: sidebar.view) != true)
        }
    }

    @Test(
        "root hit testing exposes only the revealed slice mid-animation",
        arguments: [AppearanceConfig.SidebarPosition.left, .right])
    func rootHitTestingPartialRevealSlice(position: AppearanceConfig.SidebarPosition) {
        let driver = AnimationDriver()
        let (controller, sidebar, _) = makeControlledController(position: position, driver: driver)
        controller.setSidebarWidth(300)
        controller.setPersistentSidebarVisible(false)
        controller.setOverlayPresented(true, transition: .hover, reduceMotion: false)
        let (window, offset) = hostAtNonZeroOrigin(controller)
        defer { window.orderOut(nil) }

        // Hold the reveal half-open: a 300-wide overlay translated 120pt off-edge
        // leaves a 180pt visually exposed slice against the clip.
        driver.presentationTranslation = position == .left ? -120 : 120
        let clip = controller.sidebarHostClipViewForTesting.frame
        #expect(clip.width == 300)
        func rootPoint(x: CGFloat, y: CGFloat) -> NSPoint {
            NSPoint(x: x + offset.x, y: y + offset.y)
        }

        // The on-screen edge of the slice hits the sidebar; the covered side falls
        // through to the terminal beneath.
        let exposedX = position == .left ? clip.minX + 40 : clip.maxX - 40
        let coveredX = position == .left ? clip.maxX - 40 : clip.minX + 40
        let exposedHit = controller.view.hitTest(rootPoint(x: exposedX, y: clip.midY))
        #expect(exposedHit === sidebar.view || exposedHit?.isDescendant(of: sidebar.view) == true)
        let coveredHit = controller.view.hitTest(rootPoint(x: coveredX, y: clip.midY))
        #expect(coveredHit !== sidebar.view)
        #expect(coveredHit?.isDescendant(of: sidebar.view) != true)
    }
}
