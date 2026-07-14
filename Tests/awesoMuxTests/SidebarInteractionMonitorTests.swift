import AppKit
import Testing
@testable import awesoMux

@Suite("Sidebar interaction monitor", .serialized)
@MainActor
struct SidebarInteractionMonitorTests {
    private final class FocusView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

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
