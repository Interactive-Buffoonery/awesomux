import AppKit
import AwesoMuxCore

/// A selection request survives the selected document's asynchronous render,
/// but is consumed once so subsequent reloads cannot reclaim keyboard focus.
@MainActor
final class DocumentFocusHandoff {
    private var requestedTabID: DocumentPane.ID?
    private var registeredTabID: DocumentPane.ID?
    private weak var textView: NSTextView?
    private weak var requestWindow: NSWindow?
    private weak var requestResponder: NSResponder?
    private var inputMonitor: Any?

    func request(_ tabID: DocumentPane.ID, in window: NSWindow? = NSApp.keyWindow) {
        cancel()
        guard let window, window.isKeyWindow, window.attachedSheet == nil else { return }
        requestWindow = window
        requestResponder = window.firstResponder
        requestedTabID = tabID
        inputMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            self?.handleSubsequentInput(event)
            return event
        }
        scheduleHandoff()
    }

    func register(_ textView: NSTextView, for tabID: DocumentPane.ID) {
        registeredTabID = tabID
        self.textView = textView
        if let textView = textView as? SelectionAwareTextView {
            textView.onWindowAttachment = { [weak self] in self?.scheduleHandoff() }
        }
        scheduleHandoff()
    }

    func selectedTabDidChange(to tabID: DocumentPane.ID) {
        if let requestedTabID, requestedTabID != tabID {
            cancel()
        }
    }

    func cancel() {
        requestedTabID = nil
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
    }

    isolated deinit { cancel() }

    func handleSubsequentInput(_ event: NSEvent) {
        // Ignore input that is explicitly for another window. A nil window still
        // counts: some constructed scroll events never resolve a window, and a
        // later gesture in this app still supersedes the pending selection.
        if let eventWindow = event.window, eventWindow !== requestWindow {
            return
        }
        switch event.type {
        case .scrollWheel:
            // Synthetic scroll events can lack a window; ignore those so they
            // do not cancel a pending handoff the user did not intend to abort.
            if event.window === requestWindow { cancel() }
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // A new action supersedes the earlier selection, even if it leaves
            // the same terminal as first responder while the document loads.
            cancel()
        default:
            break
        }
    }

    private func scheduleHandoff() {
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { _ = self?.completeIfReady() }
        }
    }

    @discardableResult
    func completeIfReady() -> Bool {
        guard let requestedTabID, requestedTabID == registeredTabID,
            let textView, let window = textView.window, window === requestWindow
        else { return false }
        guard window.isKeyWindow, window.attachedSheet == nil else { return false }
        let responder = window.firstResponder
        // A removed outgoing viewer can briefly leave the window vacant or
        // let the terminal reclaim it. Preserve a new, unrelated control.
        guard
            responder === requestResponder || responder === textView
                || responder == nil || responder === window || responder is GhosttySurfaceNSView
        else { return false }
        guard window.makeFirstResponder(textView) else { return false }
        cancel()
        textView.setAccessibilityFocused(true)
        NSAccessibility.post(element: textView, notification: .focusedUIElementChanged)
        return true
    }
}
