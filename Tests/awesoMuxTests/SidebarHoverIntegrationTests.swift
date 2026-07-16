import AppKit
import AwesoMuxCore
import AwesoMuxTestSupport
import Foundation
import Testing
@testable import awesoMux

@Suite("Sidebar hover integration")
@MainActor
struct SidebarHoverIntegrationTests {
    private final class AccessibilityFocusTargetView: NSView {
        private var focused = false

        override func accessibilityIdentifier() -> String {
            EmptyWorkspaceAccessibilityFocusHandoff.targetIdentifier
        }

        override func accessibilityFrame() -> NSRect {
            NSRect(x: 1, y: 1, width: 20, height: 20)
        }

        override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
            focused = accessibilityFocused
        }

        override func isAccessibilityFocused() -> Bool { focused }
    }

    @Test("persistent visibility commands drive actual hidden and split host outcomes")
    func persistentVisibilityUsesNativeHostOutcomes() throws {
        let (model, defaults, suiteName) = try makeModel(hidden: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = makeController()
        #expect(controller.setPersistentSidebarVisible(false))
        let proxy = SidebarSplitProxy()
        controller.installCommandHandlers(on: proxy)

        #expect(
            model.applyPersistentHidden(false) { visible in
                proxy.setPersistentVisible?(visible) ?? .deferredUntilHostReady
            } == .applied)
        #expect(controller.hostModeForTesting == .persistent(width: 300))
        #expect(!model.userWantsHidden)

        #expect(
            model.applyPersistentHidden(true) { visible in
                proxy.setPersistentVisible?(visible) ?? .deferredUntilHostReady
            } == .applied)
        #expect(controller.hostModeForTesting == .hidden)
        #expect(model.userWantsHidden)
    }

    @Test("hover reveal and dismissal never reparent the permanent sidebar host")
    func hoverRevealNeverReparents() {
        let controller = makeController()
        #expect(controller.setPersistentSidebarVisible(false))
        let sidebarView = controller.sidebarViewController.view
        let host = sidebarView.superview
        #expect(host === controller.sidebarHostViewForTesting)

        #expect(controller.setOverlayPresented(true, transition: .hover, reduceMotion: false))
        #expect(sidebarView.superview === host)
        #expect(controller.hostModeForTesting == .overlay(width: 300))

        controller.setOverlayPresentedImmediately(false)
        #expect(sidebarView.superview === host)
        #expect(controller.hostModeForTesting == .hidden)
        #expect(controller.sidebarHostClipViewForTesting.isHidden)
    }

    @Test("overlay transition timing follows pointer versus explicit ownership")
    func overlayTransitionTimingPolicy() {
        #expect(SidebarOverlayTransitionPolicy.resolve(source: .pointer) == .hover)
        #expect(SidebarOverlayTransitionPolicy.resolve(source: .explicit) == .immediate)
    }

    @Test("edge tab animates only for pointer-owned transitions")
    func edgeTabTransitionTimingPolicy() {
        #expect(
            SidebarEdgeTabTransitionPolicy.shouldAnimate(
                source: .pointer, reduceMotion: false))
        #expect(
            !SidebarEdgeTabTransitionPolicy.shouldAnimate(
                source: .explicit, reduceMotion: false))
        #expect(
            !SidebarEdgeTabTransitionPolicy.shouldAnimate(
                source: .pointer, reduceMotion: true))
    }

    @Test("drag pointer retention resamples outside and inside when drag state clears")
    func dragPointerRetentionPolicy() {
        #expect(
            SidebarDragPointerPolicy.hoverPublication(
                isDragActive: true,
                pointerInside: false
            ) == nil)
        #expect(
            SidebarDragPointerPolicy.clearPublication(
                wasDragActive: true,
                resampledPointerInside: false
            ) == false)
        #expect(
            SidebarDragPointerPolicy.clearPublication(
                wasDragActive: true,
                resampledPointerInside: true
            ) == true)
        #expect(
            SidebarDragPointerPolicy.clearPublication(
                wasDragActive: false,
                resampledPointerInside: false
            ) == nil)
    }

    @Test("hidden width selection routes through the proxy without revealing the host")
    func hiddenWidthSelectionStaysHidden() throws {
        let (model, defaults, suiteName) = try makeModel(hidden: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = makeController()
        #expect(controller.setPersistentSidebarVisible(false))
        let proxy = SidebarSplitProxy()
        controller.installCommandHandlers(on: proxy)
        let currentWidth = SidebarHiddenWidthTogglePolicy.currentWidth(
            committedWidth: 300,
            liveWidth: 300,
            isTemporarilyRevealed: model.isTemporarilyRevealed
        )
        let targetWidth = SidebarHiddenWidthTogglePolicy.targetWidth(
            currentWidth: currentWidth,
            lastNonCollapsedWidth: 300
        )
        proxy.setSelectedWidth?(targetWidth)

        #expect(targetWidth == SidebarWidthPolicy.collapsedWidth)
        #expect(model.proximityState == .dormant)
        #expect(model.userWantsHidden)
        #expect(controller.hostModeForTesting == .hidden)
    }

    @Test("rejected transient reveal returns to a cue and retries through the same proxy")
    func rejectedTransientRevealIsRetryable() throws {
        let (model, defaults, suiteName) = try makeModel(hidden: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = makeController()
        #expect(controller.setPersistentSidebarVisible(false))
        let peek = SidebarPeekModel()
        peek.onPointerChanged = model.peekPointerChanged
        let proxy = SidebarSplitProxy()
        controller.installCommandHandlers(on: proxy)
        let originalLayer = try #require(controller.sidebarHostViewForTesting.layer)
        controller.sidebarHostViewForTesting.layer = nil
        model.pointerMoved(x: 15, width: 100, position: .left)
        let session = TestData.session(title: "Peeked", workingDirectory: "~")
        peek.show(
            session: session,
            location: .local("~"),
            tint: ProjectTint(groupName: "Group", color: nil, index: 0),
            frame: .zero)
        peek.setPointerOverCard(true, for: session.id)

        ContentView.reconcileSidebarOverlay(
            presentation: model,
            peekModel: peek,
            proxy: proxy,
            transition: .hover,
            reduceMotion: true)

        #expect(model.proximityState == .cue)
        #expect(model.isCueVisible)
        #expect(peek.session == nil)
        #expect(controller.hostModeForTesting == .hidden)

        controller.sidebarHostViewForTesting.layer = originalLayer
        model.pointerMoved(x: 15, width: 100, position: .left)
        ContentView.reconcileSidebarOverlay(
            presentation: model,
            peekModel: peek,
            proxy: proxy,
            transition: .hover,
            reduceMotion: true)

        #expect(model.proximityState == .revealed)
        #expect(controller.hostModeForTesting == .overlay(width: 300))
    }

    @Test("focus request persists host before delivering focus to SidebarView")
    func focusDeliveryIsSerializedAfterPersistentHandoff() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/awesoMux/Views/ContentView.swift"),
            encoding: .utf8)
        let handler = try #require(
            source.range(
                of: ".onChange(of: sidebarPresentationCommandMailbox.pending, initial: true)"))
        let handlerTail = source[handler.lowerBound...]
        let nextHandler = try #require(
            handlerTail.range(of: ".onChange(of: splitProxy.commandHostGeneration"))
        let handlerBody = handlerTail[..<nextHandler.lowerBound]
        #expect(handlerBody.contains("deliverPendingSidebarPresentationCommand()"))

        let delivery = try #require(
            source.range(of: "private func deliverPendingSidebarPresentationCommand()"))
        let tail = source[delivery.lowerBound...]
        let nextFunction = tail.range(of: "private func clearInitialEmptyFocusIfEligible()")
        let body = nextFunction.map { tail[..<$0.lowerBound] } ?? tail[...]
        let persistent = try #require(body.range(of: "sidebarPresentation.applyPersistentHidden"))
        let delivered = try #require(
            body.range(of: "deliveredSidebarFocusRequestID = command.id"))

        #expect(persistent.lowerBound < delivered.lowerBound)
        #expect(source.contains("focusRequestID: deliveredSidebarFocusRequestID"))
        #expect(body.contains("if command.shouldFocusSidebar"))
    }

    @Test("persistent visibility and side changes publish only after native success")
    func explicitPresentationChangesAreTransactional() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/awesoMux/Views/ContentView.swift"),
            encoding: .utf8)

        let delivery = try #require(
            source.split(
                separator: "private func deliverPendingSidebarPresentationCommand",
                maxSplits: 1
            ).last?.split(
                separator: "private func clearInitialEmptyFocusIfEligible",
                maxSplits: 1
            ).first)
        #expect(delivery.contains("sidebarPresentation.applyPersistentHidden"))
        #expect(source.contains("splitProxy.setPersistentVisible?"))
        #expect(delivery.contains("onSidebarPersistentVisibilityChange"))

        let positionHandler = try #require(
            source.split(separator: "private func applySidebarPosition", maxSplits: 1)
                .last?.split(separator: "private func wirePeekSelection", maxSplits: 1).first)
        let nativeMove = try #require(positionHandler.range(of: "splitProxy.setPosition?(position)"))
        let modelCommit = try #require(positionHandler.range(of: "sidebarPresentation.positionDidChange()"))
        let reconciliation = try #require(
            positionHandler.range(of: "reconcileSidebarOverlay(transition: .immediate)"))
        #expect(nativeMove.lowerBound < modelCommit.lowerBound)
        #expect(modelCommit.lowerBound < reconciliation.lowerBound)
        #expect(!positionHandler.contains("splitProxy.setPosition?(position) == true"))
        #expect(!positionHandler.contains("appSettingsStore.appearance.update"))
        #expect(!positionHandler.contains("$0.sidebarPosition = appliedSidebarPosition"))
    }

    @Test("focus handoffs use only the role-aware primary content window")
    func focusHandoffsUsePrimaryContentWindow() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/awesoMux/App/AwesoMuxApp.swift"),
            encoding: .utf8)
        let focusSection = try #require(
            source.split(separator: "private func requestTerminalFocus", maxSplits: 1)
                .last?.split(separator: "private static func terminalSurface", maxSplits: 1).first)

        #expect(focusSection.contains("NSApp.awesoMuxPrimaryContentWindow"))
        #expect(!focusSection.contains("NSApp.mainWindow"))
        #expect(!focusSection.contains("NSApp.keyWindow"))
    }

    @Test("all real sidebar drag clears resample through the native proxy")
    func dragClearResamplingWiring() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sidebar = try String(
            contentsOf: root.appendingPathComponent("Sources/awesoMux/Views/SidebarView.swift"),
            encoding: .utf8)
        let split = try String(
            contentsOf: root.appendingPathComponent("Sources/awesoMux/Views/SidebarSplitView.swift"),
            encoding: .utf8)
        let controller = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/awesoMux/Views/SidebarSplitController.swift"),
            encoding: .utf8)

        let reset = try #require(
            sidebar.split(separator: "private func resetActiveDragState", maxSplits: 1)
                .last?.split(separator: "private func clearSidebarDragState", maxSplits: 1).first)
        #expect(reset.contains("resampleSidebarPointer()"))
        #expect(reset.contains("onSidebarHover(pointerInside)"))
        #expect(split.contains("controller.installCommandHandlers(on: proxy)"))
        #expect(controller.contains("proxy.resampleSidebarPointer"))
    }

    @Test("empty sidebar exposes an explicit focus destination")
    func emptySidebarFocusDestination() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sidebar = try String(
            contentsOf: root.appendingPathComponent("Sources/awesoMux/Views/SidebarView.swift"),
            encoding: .utf8)

        #expect(sidebar.contains("@FocusState private var isCollapsedEmptyActionFocused"))
        #expect(sidebar.contains("focused: $isCollapsedEmptyActionFocused"))
        #expect(sidebar.contains("isCollapsedEmptyActionFocused = true"))
    }

    @Test("empty detail focus rejects a missing or hidden AppKit target")
    @MainActor
    func emptyDetailFocusRequiresVisibleTarget() {
        let root = NSView()
        var didSetFocus = false
        let hiddenTarget = EmptyWorkspaceAccessibilityFocusTarget(
            isVisible: { false },
            setAccessibilityFocused: { _ in didSetFocus = true },
            isAccessibilityFocused: { true }
        )

        #expect(
            !EmptyWorkspaceAccessibilityFocusHandoff.focus(in: root) { _ in nil })
        #expect(
            !EmptyWorkspaceAccessibilityFocusHandoff.focus(in: root) { _ in hiddenTarget })
        #expect(!didSetFocus)
    }

    @Test("empty detail focus succeeds only after synchronous AX readback")
    @MainActor
    func emptyDetailFocusRequiresSynchronousReadback() {
        let root = NSView()
        var events: [String] = []
        var isFocused = false
        let refusingTarget = EmptyWorkspaceAccessibilityFocusTarget(
            isVisible: { true },
            setAccessibilityFocused: { _ in events.append("set") },
            isAccessibilityFocused: {
                events.append("read")
                return false
            }
        )

        #expect(
            !EmptyWorkspaceAccessibilityFocusHandoff.focus(in: root) { _ in refusingTarget })
        #expect(events == ["set", "read"])

        events.removeAll()
        let acceptingTarget = EmptyWorkspaceAccessibilityFocusTarget(
            isVisible: { true },
            setAccessibilityFocused: { focused in
                events.append("set")
                isFocused = focused
            },
            isAccessibilityFocused: {
                events.append("read")
                return isFocused
            }
        )

        #expect(
            EmptyWorkspaceAccessibilityFocusHandoff.focus(in: root) { _ in acceptingTarget })
        #expect(events == ["set", "read"])
    }

    @Test("empty detail focus searches beyond 512 earlier accessibility nodes")
    @MainActor
    func emptyDetailFocusSearchesLargeAccessibilityTree() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        for _ in 0..<600 {
            root.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1)))
        }

        let target = AccessibilityFocusTargetView(
            frame: NSRect(x: 20, y: 20, width: 20, height: 20)
        )
        root.addSubview(target)

        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = root

        #expect(EmptyWorkspaceAccessibilityFocusHandoff.focus(in: root))
        #expect(target.isAccessibilityFocused())
    }

    @Test("empty detail focus accepts a virtual parent chain beyond 64 elements")
    @MainActor
    func emptyDetailFocusSearchesDeepVirtualParentChain() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let target = NSAccessibilityElement()
        target.setAccessibilityIdentifier(
            EmptyWorkspaceAccessibilityFocusHandoff.targetIdentifier)
        target.setAccessibilityFrame(NSRect(x: 1, y: 1, width: 20, height: 20))
        var parent: Any = root
        var retainedParents: [NSAccessibilityElement] = []
        for _ in 0..<70 {
            let node = NSAccessibilityElement()
            node.setAccessibilityParent(parent)
            retainedParents.append(node)
            parent = node
        }
        target.setAccessibilityParent(parent)
        root.setAccessibilityChildren([target])
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = root

        #expect(EmptyWorkspaceAccessibilityFocusHandoff.focus(in: root))
        #expect(target.isAccessibilityFocused())
        #expect(retainedParents.count == 70)
    }

    @Test("empty detail focus rejects a cyclic virtual parent chain")
    @MainActor
    func emptyDetailFocusRejectsCyclicVirtualParentChain() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let target = NSAccessibilityElement()
        target.setAccessibilityIdentifier(
            EmptyWorkspaceAccessibilityFocusHandoff.targetIdentifier)
        target.setAccessibilityFrame(NSRect(x: 1, y: 1, width: 20, height: 20))
        let first = NSAccessibilityElement()
        let second = NSAccessibilityElement()
        first.setAccessibilityParent(second)
        second.setAccessibilityParent(first)
        target.setAccessibilityParent(first)
        root.setAccessibilityChildren([target])
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = root

        #expect(!EmptyWorkspaceAccessibilityFocusHandoff.focus(in: root))
        #expect(!target.isAccessibilityFocused())
    }

    private func makeController() -> SidebarSplitController {
        let controller = SidebarSplitController(
            sidebar: NSViewController(), detail: NSViewController())
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        controller.setSidebarWidth(300)
        return controller
    }

    private func makeModel(hidden: Bool) throws -> (
        model: SidebarPresentationModel,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName = "SidebarHoverIntegrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = SidebarPresentationPreferenceStore(defaults: defaults)
        store.saveHidden(hidden)
        return (SidebarPresentationModel(store: store), defaults, suiteName)
    }

}
