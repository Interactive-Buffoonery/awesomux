import AppKit
import DesignSystem
import SwiftUI

/// A key-capable, arrowless host avoids the system popover material and key handling.
struct AppDropdownPresenter<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let title: String
    let content: (@escaping () -> Void) -> Content

    func makeNSView(context: Context) -> NSView { NSView() }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onDismiss = { isPresented = false }
        guard isPresented else {
            coordinator.close()
            return
        }
        guard let parent = view.window else {
            coordinator.close()
            DispatchQueue.main.async { [weak view, weak coordinator] in
                if view?.window == nil { coordinator?.onDismiss?() }
            }
            return
        }
        let root = content { [weak coordinator] in coordinator?.dismiss() }
            .environment(\.awAccent, context.environment.awAccent)
            .environment(\.awGlowStrength, context.environment.awGlowStrength)
            .environment(\.awTextScale, context.environment.awTextScale)
            .environment(\.awUIFont, context.environment.awUIFont)
            .environment(\.colorScheme, context.environment.colorScheme)
            .environment(\.dynamicTypeSize, context.environment.dynamicTypeSize)
            .environment(\.locale, context.environment.locale)
            .environment(\.layoutDirection, context.environment.layoutDirection)
            .padding(EdgeInsets(top: 16, leading: 16, bottom: 28, trailing: 16))
        coordinator.show(root: AnyView(root), title: title, anchor: view, parent: parent)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.close() }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var onDismiss: (() -> Void)?
        private var panel: DropdownPanel?
        private var clickMonitor: Any?
        private weak var previousResponder: NSResponder?
        private var observers: [NSObjectProtocol] = []

        func show(root: AnyView, title: String, anchor: NSView, parent: NSWindow) {
            if let hosting = panel?.contentViewController as? NSHostingController<AnyView> {
                hosting.rootView = root
                hosting.view.layoutSubtreeIfNeeded()
                if let panel {
                    panel.setContentSize(hosting.view.fittingSize)
                    position(panel, anchor: anchor, parent: parent)
                }
                return
            }
            previousResponder = parent.firstResponder
            let hosting = NSHostingController(rootView: root)
            let size = hosting.view.fittingSize
            let panel = DropdownPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = title
            panel.setAccessibilityLabel(title)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = parent.level
            panel.worksWhenModal = true
            panel.hidesOnDeactivate = true
            panel.appearance = parent.effectiveAppearance
            panel.contentViewController = hosting
            panel.delegate = self
            panel.onCancel = { [weak self] in self?.dismiss() }
            position(panel, anchor: anchor, parent: parent)
            self.panel = panel
            parent.addChildWindow(panel, ordered: .above)
            // Only this synchronous key transfer may bypass the floating host's dismissal.
            let floatingParent = parent as? FloatingSwiftUIPanelWindow
            if !NSApp.isActive { NSApp.activate() }
            let dismissedOnResignKey = floatingParent?.dismissesOnResignKey
            floatingParent?.dismissesOnResignKey = false
            panel.makeKeyAndOrderFront(nil)
            if let dismissedOnResignKey { floatingParent?.dismissesOnResignKey = dismissedOnResignKey }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) {
                [weak self, weak anchor] event in
                guard let self, event.window !== self.panel else { return event }
                if event.type != .scrollWheel, let anchor, event.window === anchor.window,
                    anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
                {
                    self.dismiss()
                    return nil  // The trigger click closes this menu; do not let mouse-up reopen it.
                }
                self.dismiss(restoreParent: false)
                return event
            }
            for name in [
                NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willMiniaturizeNotification,
                NSWindow.willCloseNotification,
            ] {
                observers.append(
                    NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.dismiss(restoreParent: false) }
                    })
            }
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.dismiss(restoreParent: false) }
                })
        }

        private func position(_ panel: NSPanel, anchor: NSView, parent: NSWindow) {
            let size = panel.frame.size
            let rect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let screen = parent.screen?.visibleFrame ?? rect
            var origin = NSPoint(x: rect.minX - 16, y: rect.minY - size.height + 20)
            if origin.y < screen.minY { origin.y = rect.maxY - 4 - 28 }
            origin.x = min(max(screen.minX, origin.x), max(screen.minX, screen.maxX - size.width))
            origin.y = min(max(screen.minY, origin.y), max(screen.minY, screen.maxY - size.height))
            panel.setFrameOrigin(origin)
        }

        func dismiss(restoreParent: Bool = true) {
            let parent = panel?.parent
            let responder = previousResponder
            let restoreKey = panel?.isKeyWindow == true
            close()
            if restoreParent, restoreKey, NSApp.isActive {
                parent?.makeKey()
                if let view = responder as? NSView, view.window === parent { parent?.makeFirstResponder(view) }
            } else if let floating = parent as? FloatingSwiftUIPanelWindow {
                // Key may be moving back to this host; decide after the current event finishes.
                DispatchQueue.main.async { [weak floating] in
                    guard let floating, !floating.isKeyWindow, NSApp.keyWindow?.parent !== floating,
                        floating.dismissesOnResignKey, floating.attachedSheet == nil
                    else { return }
                    floating.onDismiss?()
                }
            }
            onDismiss?()
        }

        func close() {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            let closing = panel
            panel = nil
            previousResponder = nil
            closing?.delegate = nil
            if let closing { closing.parent?.removeChildWindow(closing) }
            closing?.orderOut(nil)
        }

        func windowDidResignKey(_ notification: Notification) { dismiss(restoreParent: false) }

        isolated deinit { close() }
    }
}

private final class DropdownPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func performClose(_ sender: Any?) { onCancel?() }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
