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
    private var windowObservers: [NSObjectProtocol] = []

    func request(_ tabID: DocumentPane.ID, in window: NSWindow? = NSApp.keyWindow) {
        cancel()
        guard let window, window.isKeyWindow, window.attachedSheet == nil else { return }
        requestWindow = window
        requestResponder = window.firstResponder
        requestedTabID = tabID
        inputMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            self?.handleSubsequentInput(event)
            return event
        }
        observeWindow(window)
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

    func selectedTabDidChange(to tabID: DocumentPane.ID?) {
        guard let tabID else {
            cancel()
            return
        }
        if let requestedTabID, requestedTabID != tabID {
            cancel()
        }
    }

    func cancel() {
        requestedTabID = nil
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        removeWindowObservers()
    }

    /// Keyboard already lives in the document chrome, so a remount or
    /// programmatic tab change should follow rather than leave first responder
    /// on a view that is about to unmount.
    static func isDocumentChrome(_ responder: NSResponder?) -> Bool {
        responder is SelectionAwareTextView
            || responder is BranchDiffStickyHeaderView
            || responder is DocumentTextScrollView
    }

    isolated deinit { cancel() }

    func handleSubsequentInput(_ event: NSEvent) {
        // Ignore input that is explicitly for another window. A nil window still
        // counts: some constructed events never resolve a window, and a later
        // gesture in this app still supersedes the pending selection.
        if let eventWindow = event.window, eventWindow !== requestWindow {
            return
        }
        switch event.type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // A new action supersedes the earlier selection, even if it leaves
            // the same terminal as first responder while the document loads.
            cancel()
        default:
            break
        }
    }

    private func observeWindow(_ window: NSWindow) {
        removeWindowObservers()
        let center = NotificationCenter.default
        let names = [NSWindow.didBecomeKeyNotification, NSWindow.didEndSheetNotification]
        windowObservers = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleHandoff() }
            }
        }
    }

    private func removeWindowObservers() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers = []
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
