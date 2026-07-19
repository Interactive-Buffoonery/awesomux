import AppKit
import SwiftUI
@testable import awesoMux

@MainActor
final class SidebarHostedTestWindow: NSWindow {
    struct ResponderAttempt {
        let responder: NSResponder?
        let succeeded: Bool
    }

    var reportsKey = true
    private(set) var responderAttempts: [ResponderAttempt] = []

    override var isKeyWindow: Bool { reportsKey }
    override var canBecomeKey: Bool { true }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let succeeded = super.makeFirstResponder(responder)
        responderAttempts.append(
            ResponderAttempt(responder: responder, succeeded: succeeded)
        )
        return succeeded
    }

    func resetResponderAttempts() {
        responderAttempts = []
    }
}

@MainActor
private final class SidebarHostedTestView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
enum SidebarHostedTestHarness {
    static func makeWindow<Content: View>(
        rootView: Content,
        frame: NSRect
    ) -> (window: NSWindow, hostingView: NSHostingView<Content>) {
        let hostingView = SidebarHostedTestView(rootView: rootView)
        hostingView.frame = frame
        let container = NSView(frame: frame)
        container.addSubview(hostingView)

        let window = SidebarHostedTestWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        container.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        settleMainRunLoop()
        return (window, hostingView)
    }

    static func makePrimarySplitWindow(
        controller: SidebarSplitController,
        frame: NSRect
    ) -> SidebarHostedTestWindow {
        controller.loadViewIfNeeded()
        controller.view.frame = frame
        let window = SidebarHostedTestWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.awesoMuxWindowRole = .primaryContent
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        controller.setSidebarWidth(320)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        settleMainRunLoop()
        return window
    }

    static func sendClick(to window: NSWindow, at location: CGPoint) {
        for (type, eventNumber) in [(NSEvent.EventType.leftMouseDown, 1), (.leftMouseUp, 2)] {
            guard
                let event = NSEvent.mouseEvent(
                    with: type,
                    location: location,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: eventNumber,
                    clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0
                )
            else { continue }
            window.sendEvent(event)
        }
    }

    static func sendKey(
        to window: NSWindow,
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = [],
        isRepeat: Bool = false
    ) {
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: isRepeat,
                keyCode: keyCode
            )
        else { return }
        window.sendEvent(event)
        settleMainRunLoop()
    }

    static func firstDescendant<ViewType: NSView>(
        of type: ViewType.Type,
        in root: NSView,
        where predicate: (ViewType) -> Bool = { _ in true }
    ) -> ViewType? {
        if let match = root as? ViewType, predicate(match) {
            return match
        }
        for subview in root.subviews {
            if let match = firstDescendant(of: type, in: subview, where: predicate) {
                return match
            }
        }
        return nil
    }

    static func pumpMainRunLoop(
        until condition: () -> Bool = { true },
        timeout: TimeInterval = 1.0
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            runMainRunLoopSlice()
        }
        return condition()
    }

    static func settleMainRunLoop(duration: TimeInterval = 0.05) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            runMainRunLoopSlice(maxDuration: deadline.timeIntervalSinceNow)
        }
    }

    static func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
        settleMainRunLoop()
    }

    private static func runMainRunLoopSlice(maxDuration: TimeInterval = 0.01) {
        RunLoop.main.run(until: Date().addingTimeInterval(min(0.01, max(0, maxDuration))))
    }
}
