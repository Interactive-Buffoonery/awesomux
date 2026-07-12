import AppKit

@MainActor
final class GhosttySurfaceMouseFocusMonitor {
    static let shared = GhosttySurfaceMouseFocusMonitor()

    private var monitor: Any?

    private init() {}

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let surfaceView = Self.targetSurfaceView(for: event) else {
            return event
        }

        return surfaceView.localEventLeftMouseDown(event)
    }

    private static func targetSurfaceView(for event: NSEvent) -> GhosttySurfaceNSView? {
        guard let window = event.window else {
            return nil
        }

        return targetSurfaceView(in: window, locationInWindow: event.locationInWindow)
    }

    static func targetSurfaceView(
        in window: NSWindow,
        locationInWindow: NSPoint
    ) -> GhosttySurfaceNSView? {
        guard let contentView = window.contentView else {
            return nil
        }

        // `hitTest(_:)` takes the point in the receiver's SUPERVIEW coordinate
        // space, not its own. Converting into contentView-local coords happens
        // to work for a non-flipped origin-zero view, but the window's content
        // view is SwiftUI's flipped NSHostingView, so the local point is
        // Y-MIRRORED as superview input: clicks on top chrome (the
        // needs-input banner) hit-tested to whichever surface sat near the
        // window bottom at that X and silently stole pane focus mid-click.
        // Unreachable for an installed contentView (AppKit parents it under
        // the frame view); if it ever fires mid-teardown, skipping the focus
        // transfer beats aiming one with approximated coordinates.
        guard let frameView = contentView.superview else {
            return nil
        }
        return targetSurfaceView(
            in: contentView,
            at: frameView.convert(locationInWindow, from: nil)
        )
    }

    static func targetSurfaceView(
        in contentView: NSView,
        at locationInSuperview: NSPoint
    ) -> GhosttySurfaceNSView? {
        contentView.hitTest(locationInSuperview) as? GhosttySurfaceNSView
    }
}
