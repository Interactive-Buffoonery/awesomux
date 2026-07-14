import AppKit

@MainActor
final class SidebarInteractionMonitor {
    typealias FocusedAccessibilityElement = () -> Any?

    private weak var sidebarRoot: NSView?
    private let focusedAccessibilityElement: FocusedAccessibilityElement
    private let notificationCenter: NotificationCenter
    nonisolated(unsafe) private var observations: [NSObjectProtocol] = []
    private var onActiveChange: ((Bool) -> Void)?
    private var pointerInside = false
    private var sidebarMenuTracking = false
    private var lastActive = false
    private var isDetached = false

    init(
        sidebarRoot: NSView,
        focusedAccessibilityElement: @escaping FocusedAccessibilityElement = {
            NSApp.accessibilityFocusedUIElement
        },
        notificationCenter: NotificationCenter = .default,
        onActiveChange: @escaping (Bool) -> Void
    ) {
        self.sidebarRoot = sidebarRoot
        self.focusedAccessibilityElement = focusedAccessibilityElement
        self.notificationCenter = notificationCenter
        self.onActiveChange = onActiveChange
        observeNotifications()
        refresh()
    }

    deinit {
        observations.forEach(notificationCenter.removeObserver)
    }

    func pointerChanged(_ inside: Bool) {
        guard !isDetached else { return }
        pointerInside = inside
    }

    var hasAccessibilityFocus: Bool { accessibilityFocused }

    func detach() {
        guard !isDetached else { return }
        isDetached = true
        observations.forEach(notificationCenter.removeObserver)
        observations.removeAll()
        sidebarMenuTracking = false
        lastActive = false
        onActiveChange?(false)
        onActiveChange = nil
    }

    private func observeNotifications() {
        observations.append(
            notificationCenter.addObserver(
                forName: NSWindow.didUpdateNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        observations.append(
            notificationCenter.addObserver(
                forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
            ) { [weak self] notification in
                nonisolated(unsafe) let notification = notification
                MainActor.assumeIsolated {
                    guard let self,
                        notification.object as? NSWindow === self.sidebarRoot?.window
                    else { return }
                    self.clearForWindowLoss()
                }
            })
        observations.append(
            notificationCenter.addObserver(
                forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.sidebarMenuTracking =
                        self.pointerInside || self.keyboardFocused
                        || self.accessibilityFocused
                    self.publish()
                }
            })
        observations.append(
            notificationCenter.addObserver(
                forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sidebarMenuTracking = false
                    self?.refresh()
                }
            })
    }

    private var keyboardFocused: Bool {
        guard let root = sidebarRoot, let responder = root.window?.firstResponder as? NSView else {
            return false
        }
        return responder === root || responder.isDescendant(of: root)
    }

    private var accessibilityFocused: Bool {
        containsAccessibilityElement(focusedAccessibilityElement())
    }

    private func refresh() {
        guard !isDetached else { return }
        publish()
    }

    private func clearForWindowLoss() {
        guard !isDetached else { return }
        sidebarMenuTracking = false
        if lastActive {
            lastActive = false
            onActiveChange?(false)
        }
    }

    private func publish() {
        let active = keyboardFocused || accessibilityFocused || sidebarMenuTracking
        guard active != lastActive else { return }
        lastActive = active
        onActiveChange?(active)
    }

    private func containsAccessibilityElement(_ element: Any?) -> Bool {
        guard let root = sidebarRoot, var current = element else { return false }
        for _ in 0..<32 {
            if let view = current as? NSView,
                view === root || view.isDescendant(of: root)
            {
                return true
            }
            guard let object = current as? NSAccessibilityElementProtocol,
                let parent = object.accessibilityParent()
            else { return false }
            if let parentView = parent as? NSView, parentView === root { return true }
            current = parent
        }
        return false
    }
}
