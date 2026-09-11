import AppKit

@MainActor
enum DocumentKeyViewTraversal {
    static let tabStripIdentifier = NSUserInterfaceItemIdentifier("awesomux.document-tab-strip")
    /// Test seam for Control-Tab origin. Production terminals match
    /// `GhosttySurfaceNSView` directly; tests stamp this identifier on a
    /// stand-in so they do not have to construct a live surface.
    static let terminalSurfaceIdentifier = NSUserInterfaceItemIdentifier("awesomux.terminal-surface")

    static func direction(for event: NSEvent) -> Bool? {
        guard event.type == .keyDown, event.keyCode == 48 else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers == .control || modifiers == [.control, .shift] else { return nil }
        return modifiers.contains(.shift)
    }

    @discardableResult
    static func handle(_ event: NSEvent, in window: NSWindow?, from origin: NSView? = nil) -> Bool {
        guard let backwards = direction(for: event), let window else { return false }
        if shouldLandOnTabStrip(from: origin),
            let target = tabStripKeyView(in: window, last: backwards)
        {
            moveFocus(to: target)
            return true
        }
        if let origin {
            if backwards {
                window.selectKeyView(preceding: origin)
            } else {
                window.selectKeyView(following: origin)
            }
        } else if backwards {
            window.selectPreviousKeyView(nil)
        } else {
            window.selectNextKeyView(nil)
        }
        return true
    }

    static func shouldLandOnTabStrip(from origin: NSView?) -> Bool {
        guard let origin else { return false }
        return origin is GhosttySurfaceNSView
            || origin.identifier == terminalSurfaceIdentifier
    }

    static func tabStripKeyView(in window: NSWindow, last: Bool) -> NSView? {
        let views = tabStripKeyViews(in: window)
        return last ? views.last : views.first
    }

    static func tabStripKeyViews(in window: NSWindow) -> [NSView] {
        guard let anchor = findView(identifier: tabStripIdentifier, in: window.contentView)
        else { return [] }
        let stripRect = anchor.convert(anchor.bounds, to: nil)
        guard !stripRect.isNull, stripRect.width > 0, stripRect.height > 0 else { return [] }
        var views: [NSView] = []
        func walk(_ view: NSView) {
            if view !== anchor, view.canBecomeKeyView {
                let rect = view.convert(view.bounds, to: nil)
                if stripRect.intersects(rect) {
                    views.append(view)
                }
            }
            for child in view.subviews { walk(child) }
        }
        window.contentView.map(walk)
        views.sort {
            $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
        }
        return views
    }

    @discardableResult
    static func moveFocus(to view: NSView) -> Bool {
        guard let window = view.window, window.makeFirstResponder(view) else { return false }
        view.setAccessibilityFocused(true)
        NSAccessibility.post(element: view, notification: .focusedUIElementChanged)
        return true
    }

    private static func findView(
        identifier: NSUserInterfaceItemIdentifier, in root: NSView?
    ) -> NSView? {
        guard let root else { return nil }
        if root.identifier == identifier { return root }
        for child in root.subviews {
            if let found = findView(identifier: identifier, in: child) { return found }
        }
        return nil
    }
}
