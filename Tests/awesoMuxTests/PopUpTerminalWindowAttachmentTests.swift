import AppKit
import Testing
@testable import awesoMux

@Suite("Terminal Companion window attachment")
@MainActor
struct PopUpTerminalWindowAttachmentTests {
    @Test("reattaches an ordered-out destination before presentation")
    func reattachesOrderedOutDestination() {
        _ = NSApplication.shared
        let parent = makeWindow(size: NSSize(width: 800, height: 600))
        let destination = makePanel(size: NSSize(width: 260, height: 48))
        defer {
            destination.parent?.removeChildWindow(destination)
            destination.close()
            parent.close()
        }

        parent.addChildWindow(destination, ordered: .above)
        destination.orderOut(nil)
        #expect(destination.parent == nil)

        PopUpTerminalWindowAttachment.attach(destination, to: parent)

        #expect(destination.parent === parent)
    }

    @Test("keeps each destination attached across repeated transitions")
    func repeatedTransitionsKeepDestinationAttached() {
        _ = NSApplication.shared
        let parent = makeWindow(size: NSSize(width: 800, height: 600))
        let expanded = makePanel(size: NSSize(width: 640, height: 420))
        let corner = makePanel(size: NSSize(width: 260, height: 48))
        defer {
            expanded.parent?.removeChildWindow(expanded)
            corner.parent?.removeChildWindow(corner)
            expanded.close()
            corner.close()
            parent.close()
        }

        parent.addChildWindow(expanded, ordered: .above)
        parent.addChildWindow(corner, ordered: .above)
        var source = corner
        var destination = expanded

        for _ in 0..<10 {
            PopUpTerminalWindowAttachment.attach(destination, to: parent)
            destination.orderFrontRegardless()
            source.orderOut(nil)
            #expect(destination.parent === parent)
            swap(&source, &destination)
        }
    }

    @Test("no-op inputs leave an existing attachment unchanged")
    func noOpInputsLeaveAttachmentUnchanged() {
        _ = NSApplication.shared
        let parent = makeWindow(size: NSSize(width: 800, height: 600))
        let destination = makePanel(size: NSSize(width: 260, height: 48))
        defer {
            destination.parent?.removeChildWindow(destination)
            destination.close()
            parent.close()
        }

        // Re-attach to the current parent, nil window, nil parent: none may
        // duplicate the child entry or detach the existing attachment.
        PopUpTerminalWindowAttachment.attach(destination, to: parent)
        PopUpTerminalWindowAttachment.attach(destination, to: parent)
        PopUpTerminalWindowAttachment.attach(nil, to: parent)
        PopUpTerminalWindowAttachment.attach(destination, to: nil)

        #expect(destination.parent === parent)
        #expect(parent.childWindows?.count == 1)
        #expect(parent.childWindows?.first === destination)
    }

    @Test("moves a destination from a stale parent to the current parent")
    func movesDestinationToCurrentParent() {
        _ = NSApplication.shared
        let staleParent = makeWindow(size: NSSize(width: 600, height: 400))
        let currentParent = makeWindow(size: NSSize(width: 800, height: 600))
        let destination = makePanel(size: NSSize(width: 260, height: 48))
        defer {
            destination.parent?.removeChildWindow(destination)
            destination.close()
            staleParent.close()
            currentParent.close()
        }

        staleParent.addChildWindow(destination, ordered: .above)

        PopUpTerminalWindowAttachment.attach(destination, to: currentParent)

        #expect(destination.parent === currentParent)
        #expect(staleParent.childWindows?.isEmpty == true)
        #expect(currentParent.childWindows?.first === destination)
    }

    private func makeWindow(size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func makePanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        return panel
    }
}
