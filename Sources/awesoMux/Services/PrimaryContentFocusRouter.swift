import AppKit
import AwesoMuxCore

@MainActor
enum PrimaryContentFocusRouter {
    static func focus(
        _ request: SidebarFocusHandoffRequest,
        sessionStore: SessionStore,
        application: NSApplication = .shared,
        primaryContentWindow: (NSApplication) -> NSWindow? = {
            $0.awesoMuxPrimaryContentWindow
        },
        applicationIsActive: () -> Bool = { NSApp.isActive }
    ) -> SidebarFocusHandoffOutcome? {
        guard let window = primaryContentWindow(application) else {
            return nil
        }
        guard applicationIsActive(), window.isVisible, window.isKeyWindow else {
            return nil
        }
        guard let session = sessionStore.selectedSession else {
            guard
                let target = EmptyWorkspaceAccessibilityFocusHandoff.target(
                    in: window.contentView) as? NSView
            else { return nil }
            if request.requiresKeyboardFocus {
                guard window.makeFirstResponder(target) else { return nil }
            }
            if request.requiresAccessibilityFocus {
                target.setAccessibilityFocused(true)
                guard target.isAccessibilityFocused() else { return nil }
            }
            return SidebarFocusHandoffOutcome(
                destination: target,
                keyboardFocusSucceeded: request.requiresKeyboardFocus,
                accessibilityFocusSucceeded: request.requiresAccessibilityFocus)
        }
        guard session.activePane?.remoteReconnect == nil else {
            return nil
        }
        guard
            let surface = terminalSurface(
                in: window.contentView,
                sessionID: session.id,
                paneID: session.activePaneID
            )
        else { return nil }
        if request.requiresKeyboardFocus,
            !window.makeFirstResponder(surface)
        {
            return nil
        }
        if request.requiresAccessibilityFocus {
            surface.setAccessibilityFocused(true)
            guard surface.isAccessibilityFocused() else { return nil }
        }
        return SidebarFocusHandoffOutcome(
            destination: surface,
            keyboardFocusSucceeded: request.requiresKeyboardFocus,
            accessibilityFocusSucceeded: request.requiresAccessibilityFocus)
    }

    static func terminalSurface(
        in view: NSView?,
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID
    ) -> GhosttySurfaceNSView? {
        guard let view else { return nil }
        if let surface = view as? GhosttySurfaceNSView,
            surface.sessionID == sessionID,
            surface.paneID == paneID
        {
            return surface
        }
        for subview in view.subviews {
            if let surface = terminalSurface(
                in: subview,
                sessionID: sessionID,
                paneID: paneID
            ) {
                return surface
            }
        }
        return nil
    }
}
