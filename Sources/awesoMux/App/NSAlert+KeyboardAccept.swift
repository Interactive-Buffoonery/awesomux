import AppKit
import DesignSystem

extension NSAlert {
    /// The canonical destructive confirmation dialog. Every destructive
    /// confirm in the app goes through here (or hand-rolls the exact same
    /// shape, pending migration) so they all look and behave identically:
    /// Cancel is added first so it is the default button — Return and Esc
    /// both cancel — the destructive action renders second with
    /// `hasDestructiveAction`, the keyboard hint rides the body copy, and
    /// ⌘Return accepts via the keyboard-accept monitor (a keyEquivalent
    /// would be stripped by NSAlert.layout()).
    ///
    /// `keyboardHint` should be verb-specific ("Press ⌘Return to close
    /// group. Esc cancels."), matching `AwModalConfiguration`'s convention.
    @MainActor
    static func confirmDestructive(
        title: String,
        body: String,
        keyboardHint: String,
        destructiveTitle: String,
        cancelTitle: String = String(
            localized: "Cancel",
            comment: "Default button on a destructive confirmation dialog. Cancels the action."
        ),
        destructiveAccessibilityLabel: String? = nil,
        cancelAccessibilityLabel: String? = nil,
        accessoryView: NSView? = nil
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = body + "\n\n" + keyboardHint
        alert.accessoryView = accessoryView
        let cancelButton = alert.addButton(withTitle: cancelTitle)
        if let cancelAccessibilityLabel {
            cancelButton.setAccessibilityLabel(cancelAccessibilityLabel)
        }
        let destructiveButton = alert.addButton(withTitle: destructiveTitle)
        destructiveButton.hasDestructiveAction = true
        if let destructiveAccessibilityLabel {
            destructiveButton.setAccessibilityLabel(destructiveAccessibilityLabel)
        }
        return alert.runModal(keyboardAccept: destructiveButton) == .alertSecondButtonReturn
    }

    @MainActor
    func runModal(keyboardAccept acceptButton: NSButton?) -> NSApplication.ModalResponse {
        withKeyboardAcceptMonitor(acceptButton: acceptButton) {
            runModal()
        }
    }

    /// Presents the alert as a sheet with the ⌘Return accept monitor
    /// installed. The completion handler is load-bearing: it is the only
    /// place the monitor is removed, so every path that ends the sheet must
    /// go through it (endSheet does; never orderOut the sheet directly).
    @MainActor
    func beginSheetModal(
        for sheetWindow: NSWindow,
        keyboardAccept acceptButton: NSButton?,
        completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil
    ) {
        // A window already presenting a sheet silently queues this alert
        // behind it — the monitor would then outlive the interaction the
        // caller reasoned about. Callers pick sheet-free windows.
        assert(sheetWindow.attachedSheet == nil)
        let acceptMonitor = installKeyboardAcceptMonitor(acceptButton: acceptButton)
        beginSheetModal(for: sheetWindow) { response in
            if let acceptMonitor {
                NSEvent.removeMonitor(acceptMonitor)
            }
            handler?(response)
        }
    }

    @MainActor
    private func withKeyboardAcceptMonitor<T>(
        acceptButton: NSButton?,
        operation: () -> T
    ) -> T {
        let acceptMonitor = installKeyboardAcceptMonitor(acceptButton: acceptButton)
        defer {
            if let acceptMonitor {
                NSEvent.removeMonitor(acceptMonitor)
            }
        }
        return operation()
    }

    @MainActor
    private func installKeyboardAcceptMonitor(acceptButton: NSButton?) -> Any? {
        // ⌘Return accept has to be an event monitor, not a button
        // keyEquivalent: NSAlert.layout() strips a Return-family
        // keyEquivalent from destructive buttons at every layout pass.
        guard let acceptButton else {
            return nil
        }

        // Strong self on purpose: the monitor must keep the alert alive for
        // the async sheet's lifetime rather than relying on AppKit privately
        // retaining it. Cycle-free — the alert does not retain the monitor;
        // the completion handler removes it, releasing the alert. Strong self
        // also makes `self.window` non-optional, closing the nil === nil
        // window-match sliver a weak capture had.
        return NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self, weak acceptButton] event in
            guard let acceptButton,
                event.window === self.window,
                AwKeyboardAcceptChord.isKeyboardAcceptKeyDown(
                    keyCode: event.keyCode,
                    modifiers: event.modifierFlags
                )
            else {
                return event
            }
            acceptButton.performClick(nil)
            return nil
        }
    }
}
