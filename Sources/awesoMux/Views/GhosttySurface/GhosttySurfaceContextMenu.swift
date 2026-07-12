import AppKit
import GhosttyKit

/// Suppresses the AppKit context menu on ctrl+left-click while the terminal
/// app has mouse-capture mode enabled (vim `:set mouse=a`, htop, etc.), so
/// the click reaches the app as a real mouse event instead of popping a menu.
///
/// Mirrors the ctrl+left-click branch of `SurfaceView_AppKit.menu(for:)` in
/// `vendor/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift:1536-1606`.
/// Ghostty's reference also builds a full custom menu for right-click and for
/// ctrl+left-click when NOT captured; awesoMux has no menu content to show
/// today (`GhosttySurfaceNSView` has never had a `menu` set), so only the
/// mouse-capture suppression is ported here. Every other case — including
/// right-click — defers to `super.menu(for:)` so this is a pure addition,
/// not a behavior change, for anything but the exact suppressed case.
extension GhosttySurfaceNSView {
    override func menu(for event: NSEvent) -> NSMenu? {
        guard event.type == .leftMouseDown,
              event.modifierFlags.contains(.control),
              let surface,
              ghostty_surface_mouse_captured(surface)
        else {
            return super.menu(for: event)
        }

        return nil
    }
}
