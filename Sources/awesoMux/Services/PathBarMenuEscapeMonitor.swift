import AppKit

/// Escape-to-dismiss for the path bar's foldout menus.
///
/// The foldouts never take key focus (the terminal keeps first responder by
/// design), so focus-based handling (`.onExitCommand`) can never fire; a local
/// key-down monitor catches Escape first. The monitor is class-owned rather
/// than a raw token in `@State` because SwiftUI is not contractually required
/// to send `.onDisappear` before tearing down the view tree (see
/// `SettingsEscapeMonitor`, which documents the same hazard) — and unlike that
/// monitor's inert leak, a leaked foldout monitor would consume EVERY Escape
/// app-wide. `isolated deinit` guarantees removal when the owning `@State`
/// box releases, even if `.onDisappear` never arrives.
@MainActor
final class PathBarMenuEscapeMonitor {
    private var monitor: Any?

    /// Idempotent: a second `start` while active keeps the existing monitor
    /// (and its captured dismiss) rather than stacking a duplicate.
    func start(onEscape: @escaping @MainActor () -> Void) {
        guard monitor == nil else { return }
        // keyDown local monitors fire on the main thread, so calling the
        // main-actor `onEscape` from the handler is safe.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event } // 53 = Escape
            onEscape()
            return nil // consume: don't also send Esc to the terminal
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    // Backstop teardown; `.onChange(of: presentedMenu)` and `.onDisappear`
    // are the prompt paths. `isolated deinit` hops to main-actor isolation so
    // it can touch the non-Sendable token and call the main-thread-only
    // `NSEvent.removeMonitor`.
    isolated deinit {
        stop()
    }
}
