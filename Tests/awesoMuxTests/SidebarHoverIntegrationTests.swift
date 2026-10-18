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

    @Test("stale or mismatched pane drops preserve gesture identity")
    func staleOrMismatchedPaneDropNeverMovesAPane() throws {
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

        // A drop decoder can finish after AppKit ends this drag or a newer drag.
        // Only the captured generation may move the captured running pane.
        let first = TerminalPane(title: "first", workingDirectory: "~", executionPlan: .local)
        let second = TerminalPane(title: "second", workingDirectory: "~", executionPlan: .local)
        let source = TerminalSession(
            title: "source", workingDirectory: "~",
            layout: .split(
                TerminalSplit(
                    orientation: .horizontal, first: .pane(first), second: .pane(second),
                    firstFraction: 0.5)))
        let other = TerminalSession(title: "other", workingDirectory: "~")
        let store = SessionStore(groups: [SessionGroup(name: "work", sessions: [source, other])])
        let coordinator = PaneDragCoordinator()
        let delegate = SidebarPaneDropDelegate(
            sessionID: source.id, sessionStore: store, coordinator: coordinator,
            setTargeted: { _ in })
        let wrongRow = SidebarPaneDropDelegate(
            sessionID: other.id, sessionStore: store, coordinator: coordinator,
            setTargeted: { _ in })
        let provider = NSItemProvider(object: "pane" as NSString)
        var completion: (@MainActor (PaneDragItem?) -> Void)?
        let staleID = coordinator.begin(sessionID: source.id, paneID: first.id)
        #expect(delegate.canAcceptDrop)
        #expect(!wrongRow.canAcceptDrop)
        #expect(delegate.performDrop(from: provider, decode: { _, callback in completion = callback }))
        coordinator.end()
        _ = coordinator.begin(sessionID: source.id, paneID: second.id)
        coordinator.end()
        let decoded1 = try #require(completion)
        decoded1(PaneDragItem(sessionID: source.id, paneID: first.id, dragID: staleID))
        #expect(store.groups[0].sessions.count == 2)
        #expect(store.session(id: source.id)?.layout.paneIDs == [first.id, second.id])

        let rejectedID = coordinator.begin(sessionID: source.id, paneID: first.id)
        #expect(delegate.performDrop(from: provider, decode: { _, callback in completion = callback }))
        let decoded2 = try #require(completion)
        decoded2(PaneDragItem(sessionID: other.id, paneID: first.id, dragID: rejectedID))
        #expect(store.groups[0].sessions.count == 2)
        _ = coordinator.begin(sessionID: source.id, paneID: first.id)
        #expect(delegate.performDrop(from: provider, decode: { _, callback in completion = callback }))
        let decoded3 = try #require(completion)
        decoded3(nil)
        #expect(store.groups[0].sessions.count == 2)

        let acceptedID = coordinator.begin(sessionID: source.id, paneID: first.id)
        #expect(delegate.performDrop(from: provider, decode: { _, callback in completion = callback }))
        coordinator.end()
        let decoded4 = try #require(completion)
        decoded4(PaneDragItem(sessionID: source.id, paneID: first.id, dragID: acceptedID))
        let moved = try #require(store.groups[0].sessions.dropFirst().first)
        #expect(store.groups[0].sessions.map(\.id) == [source.id, moved.id, other.id])
        #expect(store.selectedSessionID == moved.id)
        #expect(moved.activePaneID == first.id)
        #expect(moved.layout.pane(id: first.id)?.terminalSessionID == first.terminalSessionID)
        #expect(moved.moveOrigin?.sourceSessionID == source.id)
        _ = coordinator.begin(sessionID: source.id, paneID: second.id)
        #expect(!delegate.canAcceptDrop)
        coordinator.end()
        #expect(store.returnPaneToSourceWorkspace(sessionID: moved.id))
        #expect(store.session(id: source.id)?.layout.paneIDs == [first.id, second.id])
        let closedID = coordinator.begin(sessionID: source.id, paneID: first.id)
        #expect(delegate.performDrop(from: provider, decode: { _, callback in completion = callback }))
        _ = store.closePane(id: first.id, in: source.id)
        let decoded5 = try #require(completion)
        decoded5(PaneDragItem(sessionID: source.id, paneID: first.id, dragID: closedID))
        #expect(store.groups[0].sessions.count == 2)
        _ = coordinator.begin(sessionID: UUID(), paneID: second.id)
        #expect(!delegate.canAcceptDrop)
        coordinator.end()

        let remote = TerminalPane(
            title: "remote", workingDirectory: "~",
            executionPlan: .ssh(SSHExecution(target: try #require(RemoteTarget(user: "test", host: "example.com")))))
        let remoteSource = TerminalSession(
            title: "remote source", workingDirectory: "~",
            layout: .split(
                TerminalSplit(
                    orientation: .horizontal, first: .pane(remote), second: .pane(second),
                    firstFraction: 0.5)))
        let remoteStore = SessionStore(groups: [SessionGroup(name: "remote", sessions: [remoteSource])])
        let remoteDelegate = SidebarPaneDropDelegate(
            sessionID: remoteSource.id, sessionStore: remoteStore, coordinator: coordinator,
            setTargeted: { _ in })
        _ = coordinator.begin(sessionID: remoteSource.id, paneID: remote.id)
        #expect(!remoteDelegate.canAcceptDrop)
        coordinator.end()
    }

    @Test(arguments: ["missing", "hidden", "refusing", "accepting"])
    func emptyDetailFocus(scenario: String) {
        let root = NSView()
        var events: [String] = []
        var focused = false
        let target = EmptyWorkspaceAccessibilityFocusTarget(
            isVisible: { scenario != "hidden" },
            setAccessibilityFocused: {
                focused = $0; events.append("set")
            },
            isAccessibilityFocused: {
                events.append("read"); return scenario == "accepting" && focused
            })
        #expect(
            EmptyWorkspaceAccessibilityFocusHandoff.focus(in: root) { _ in scenario == "missing" ? nil : target }
                == (scenario == "accepting"))
        #expect(events == (["missing", "hidden"].contains(scenario) ? [] : ["set", "read"]))
    }

    @Test(arguments: ["large", "deep", "cyclic"])
    func focusTargetSearch(scenario: String) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let target: any NSAccessibilityProtocol
        var parents: [NSAccessibilityElement] = []
        if scenario == "large" {
            for _ in 0..<600 { root.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))) }
            let view = AccessibilityFocusTargetView(frame: NSRect(x: 20, y: 20, width: 20, height: 20))
            root.addSubview(view)
            target = view
        } else {
            let element = NSAccessibilityElement()
            element.setAccessibilityIdentifier(EmptyWorkspaceAccessibilityFocusHandoff.targetIdentifier)
            element.setAccessibilityFrame(NSRect(x: 1, y: 1, width: 20, height: 20))
            if scenario == "deep" {
                var parent: Any = root
                for _ in 0..<70 {
                    let node = NSAccessibilityElement()
                    node.setAccessibilityParent(parent)
                    parents.append(node)
                    parent = node
                }
                element.setAccessibilityParent(parent)
                #expect(parents.count == 70)
            } else {
                let first = NSAccessibilityElement(), second = NSAccessibilityElement()
                first.setAccessibilityParent(second); second.setAccessibilityParent(first)
                element.setAccessibilityParent(first)
                parents = [first, second]
            }
            root.setAccessibilityChildren([element])
            target = element
        }
        let window = NSWindow(contentRect: root.bounds, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.contentView = nil; window.close(); withExtendedLifetime(parents) {} }
        #expect(EmptyWorkspaceAccessibilityFocusHandoff.focus(in: root) == (scenario != "cyclic"))
        #expect(target.isAccessibilityFocused() == (scenario != "cyclic"))
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
