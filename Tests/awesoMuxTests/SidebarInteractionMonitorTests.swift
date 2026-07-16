import AppKit
import Testing
@testable import awesoMux

@Suite("Sidebar interaction monitor", .serialized)
@MainActor
struct SidebarInteractionMonitorTests {
    private final class FocusView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private final class TextViewDelegateView: NSView, NSTextViewDelegate {}

    @Test("keyboard focus inside sidebar reports active and detach reports false once")
    func keyboardFocusAndDetach() throws {
        let center = NotificationCenter()
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let focus = FocusView(frame: .zero)
        root.addSubview(focus)
        let window = NSWindow(contentRect: root.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = root
        #expect(window.makeFirstResponder(focus))
        var changes: [Bool] = []
        let monitor = SidebarInteractionMonitor(
            sidebarRoot: root,
            focusedAccessibilityElement: { nil },
            notificationCenter: center,
            onActiveChange: { changes.append($0) })

        center.post(name: NSWindow.didUpdateNotification, object: window)
        monitor.detach()
        monitor.detach()

        #expect(changes == [true, false])
    }

    @Test("search field editor resolves to its sidebar owner during window updates")
    func searchFieldEditorUsesSidebarOwner() throws {
        let center = NotificationCenter()
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let searchField = NSSearchField(
            frame: CGRect(x: 12, y: 160, width: 160, height: 24))
        root.addSubview(searchField)
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [],
            backing: .buffered,
            defer: false)
        window.contentView = root
        searchField.selectText(nil)
        let fieldEditor = try #require(searchField.currentEditor() as? NSTextView)
        #expect(window.firstResponder === fieldEditor)
        #expect(SidebarInteractionMonitor.keyboardFocusOwner(for: fieldEditor) === searchField)
        var changes: [Bool] = []
        let monitor = SidebarInteractionMonitor(
            sidebarRoot: root,
            focusedAccessibilityElement: { nil },
            notificationCenter: center,
            isAccessibilityRefreshRelevant: { false },
            onActiveChange: { changes.append($0) })
        #expect(changes == [true])

        fieldEditor.string = "workspace"
        center.post(name: NSWindow.didUpdateNotification, object: window)

        #expect(monitor.isActive)
        #expect(changes == [true])
    }

    @Test("direct sidebar text view remains active despite an external view delegate")
    func directTextViewUsesItselfAsKeyboardFocusOwner() {
        let center = NotificationCenter()
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let textView = NSTextView(
            frame: CGRect(x: 12, y: 80, width: 160, height: 80))
        let delegate = TextViewDelegateView(
            frame: CGRect(x: 220, y: 80, width: 160, height: 80))
        content.addSubview(root)
        content.addSubview(delegate)
        root.addSubview(textView)
        textView.delegate = delegate
        let window = NSWindow(
            contentRect: content.bounds,
            styleMask: [],
            backing: .buffered,
            defer: false)
        window.contentView = content
        #expect(!textView.isFieldEditor)
        #expect(window.makeFirstResponder(textView))
        var changes: [Bool] = []

        let monitor = SidebarInteractionMonitor(
            sidebarRoot: root,
            focusedAccessibilityElement: { nil },
            notificationCenter: center,
            onActiveChange: { changes.append($0) })

        #expect(monitor.isActive)
        #expect(changes == [true])
    }

    @Test("menu tracking is attributed to pointer inside sidebar")
    func menuTrackingAttribution() {
        let center = NotificationCenter()
        let root = NSView()
        var changes: [Bool] = []
        let monitor = SidebarInteractionMonitor(
            sidebarRoot: root,
            focusedAccessibilityElement: { nil },
            notificationCenter: center,
            onActiveChange: { changes.append($0) })
        monitor.pointerChanged(true)

        center.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        monitor.pointerChanged(false)
        center.post(name: NSMenu.didEndTrackingNotification, object: nil)

        #expect(changes == [true, false])
    }

    @Test("accessibility parent chain reaching sidebar reports active")
    func accessibilityParentChain() {
        let center = NotificationCenter()
        let root = NSView()
        let child = NSView()
        root.addSubview(child)
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.contentView = root
        var focused: Any? = child
        var changes: [Bool] = []
        let monitor = SidebarInteractionMonitor(
            sidebarRoot: root,
            focusedAccessibilityElement: { focused },
            notificationCenter: center,
            onActiveChange: { changes.append($0) })

        center.post(name: NSWindow.didUpdateNotification, object: window)
        focused = nil
        center.post(name: NSWindow.didUpdateNotification, object: window)

        #expect(changes == [true, false])
        monitor.detach()
    }

    @Test("implicit refreshes poll accessibility only for relevant non-window events")
    func implicitAccessibilityQueriesAreRelevanceGated() {
        let center = NotificationCenter()
        let root = NSView()
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.contentView = root
        var isAccessibilityRefreshRelevant = false
        var accessibilityQueryCount = 0
        let monitor = SidebarInteractionMonitor(
            sidebarRoot: root,
            focusedAccessibilityElement: {
                accessibilityQueryCount += 1
                return nil
            },
            notificationCenter: center,
            isAccessibilityRefreshRelevant: { isAccessibilityRefreshRelevant },
            onActiveChange: { _ in })
        #expect(accessibilityQueryCount == 0)

        for _ in 0..<100 {
            center.post(name: NSWindow.didUpdateNotification, object: window)
        }
        monitor.synchronizeActiveState()
        center.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        center.post(name: NSMenu.didEndTrackingNotification, object: nil)
        #expect(accessibilityQueryCount == 0)

        _ = monitor.hasAccessibilityFocus
        #expect(accessibilityQueryCount == 1)

        isAccessibilityRefreshRelevant = true
        for _ in 0..<100 {
            center.post(name: NSWindow.didUpdateNotification, object: window)
        }
        #expect(accessibilityQueryCount == 1)

        monitor.synchronizeActiveState()
        center.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        center.post(name: NSMenu.didEndTrackingNotification, object: nil)
        #expect(accessibilityQueryCount == 4)
    }

    @Test("accessibility parent traversal reaches sidebar beyond 32 virtual elements")
    func deepAccessibilityParentChain() {
        let root = NSView()
        let monitor = SidebarInteractionMonitor(sidebarRoot: root, onActiveChange: { _ in })
        var parent: Any = root
        var retainedNodes: [NSAccessibilityElement] = []
        for _ in 0..<40 {
            let node = NSAccessibilityElement()
            node.setAccessibilityParent(parent)
            retainedNodes.append(node)
            parent = node
        }

        #expect(monitor.containsAccessibilityElement(parent))
        #expect(retainedNodes.count == 40)
    }

    @Test("cyclic accessibility parents terminate outside sidebar")
    func cyclicAccessibilityParentChain() {
        let root = NSView()
        let monitor = SidebarInteractionMonitor(sidebarRoot: root, onActiveChange: { _ in })
        let first = NSAccessibilityElement()
        let second = NSAccessibilityElement()
        first.setAccessibilityParent(second)
        second.setAccessibilityParent(first)

        #expect(!monitor.containsAccessibilityElement(first))
    }

    @Test("another window resigning key does not clear sidebar interaction")
    func unrelatedWindowResignationIsIgnored() {
        let center = NotificationCenter()
        let root = NSView()
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.contentView = root
        let otherWindow = NSWindow(
            contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        var focused: Any? = root
        var changes: [Bool] = []
        let monitor = SidebarInteractionMonitor(
            sidebarRoot: root,
            focusedAccessibilityElement: { focused },
            notificationCenter: center,
            onActiveChange: { changes.append($0) })
        #expect(monitor.observerCountForTesting == 4)

        center.post(name: NSWindow.didResignKeyNotification, object: otherWindow)
        #expect(changes == [true])

        focused = nil
        center.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(changes == [true, false])
        monitor.detach()
        #expect(monitor.observerCountForTesting == 0)
    }
}
