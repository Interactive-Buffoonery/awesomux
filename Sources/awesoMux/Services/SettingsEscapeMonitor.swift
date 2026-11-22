import AppKit

/// Closes the Settings window on a bare Escape press.
///
/// The `Settings` scene leaves nothing in its responder chain when no control
/// is focused, so SwiftUI's `.onExitCommand` / `@Environment(\.dismiss)` never
/// fire and Escape falls through to the system beep. A local key-down monitor,
/// scoped to the Settings view's on-screen lifetime, catches the key first and
/// closes the captured window directly.
@MainActor
final class SettingsEscapeMonitor {
    /// The Settings `NSWindow`, captured by a `WindowAccessor` in the view tree.
    /// Matching events against this exact window means a monitor that outlives
    /// its window (if `.onDisappear` is late) is harmless: no event targets it.
    weak var window: NSWindow?

    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        // keyDown local monitors fire on the main thread, so touching
        // main-actor state in the handler is safe.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    // Backstop teardown. `.onDisappear` calls `stop()` when Settings closes, but
    // SwiftUI is not contractually required to send it before tearing down the
    // view tree, so a missed callback would leak the app-wide monitor across
    // open/close cycles. (The leak is inert thanks to the `[weak self]` capture
    // and the `event.window === window` guard, but it is still a leak.)
    // `isolated deinit` hops to this type's main-actor isolation so it can touch
    // the non-Sendable monitor token and call the main-thread-only
    // `NSEvent.removeMonitor`.
    isolated deinit {
        stop()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard FloatingPanelEventPolicy.isDismissChord(
            type: event.type,
            keyCode: event.keyCode,
            isARepeat: event.isARepeat,
            modifiers: event.modifierFlags
        ) else {
            return event
        }

        // Only act on the captured Settings window, and let a focused field
        // editor (the sidebar search) consume Escape first so it clears its
        // text rather than closing the window.
        guard let window,
              event.window === window,
              !(window.firstResponder is NSText)
        else {
            return event
        }

        window.performClose(nil)
        return nil
    }
}
