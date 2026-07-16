import AppKit

@MainActor
final class SidebarInteractionMonitor {
    typealias FocusedAccessibilityElement = () -> Any?

    private weak var sidebarRoot: NSView?
    private let focusedAccessibilityElement: FocusedAccessibilityElement
    private let notificationCenter: NotificationCenter
    private let isAccessibilityRefreshRelevant: () -> Bool
    nonisolated(unsafe) private var observations: [NSObjectProtocol] = []
    private var onActiveChange: ((Bool) -> Void)?
    private var pointerInside = false
    private var sidebarMenuTracking = false
    private var lastAccessibilityFocused = false
    private var lastActive = false
    private var isDetached = false

    var observerCountForTesting: Int { observations.count }

    init(
        sidebarRoot: NSView,
        focusedAccessibilityElement: FocusedAccessibilityElement? = nil,
        notificationCenter: NotificationCenter = .default,
        isAccessibilityRefreshRelevant: @escaping () -> Bool = { true },
        onActiveChange: @escaping (Bool) -> Void
    ) {
        self.sidebarRoot = sidebarRoot
        self.focusedAccessibilityElement =
            focusedAccessibilityElement ?? { NSApp.accessibilityFocusedUIElement }
        self.notificationCenter = notificationCenter
        self.isAccessibilityRefreshRelevant = isAccessibilityRefreshRelevant
        self.onActiveChange = onActiveChange
        observeNotifications()
        refresh(includeAccessibilityFocus: isAccessibilityRefreshRelevant())
    }

    deinit {
        observations.forEach(notificationCenter.removeObserver)
    }

    func pointerChanged(_ inside: Bool) {
        guard !isDetached else { return }
        pointerInside = inside
    }

    var hasAccessibilityFocus: Bool {
        refresh(includeAccessibilityFocus: true)
        return lastAccessibilityFocused
    }
    var isActive: Bool { lastActive }
    var focusedAccessibilityElementInsideSidebar: Any? {
        let element = focusedAccessibilityElement()
        return containsAccessibilityElement(element) ? element : nil
    }

    func detach() {
        guard !isDetached else { return }
        isDetached = true
        observations.forEach(notificationCenter.removeObserver)
        observations.removeAll()
        sidebarMenuTracking = false
        if lastActive {
            lastActive = false
            onActiveChange?(false)
        }
        onActiveChange = nil
    }

    func synchronizeActiveState() {
        refresh(includeAccessibilityFocus: isAccessibilityRefreshRelevant())
    }

    private func observeNotifications() {
        observations.append(
            notificationCenter.addObserver(
                forName: NSWindow.didUpdateNotification, object: nil, queue: .main
            ) { [weak self] notification in
                nonisolated(unsafe) let notification = notification
                MainActor.assumeIsolated {
                    guard let self,
                        notification.object as? NSWindow === self.sidebarRoot?.window
                    else { return }
                    self.refresh(includeAccessibilityFocus: self.lastAccessibilityFocused)
                }
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
                    let includeAccessibilityFocus = self.isAccessibilityRefreshRelevant()
                    let keyboardFocused = self.keyboardFocused
                    if includeAccessibilityFocus {
                        self.lastAccessibilityFocused = self.accessibilityFocused
                    }
                    self.sidebarMenuTracking =
                        self.pointerInside || keyboardFocused || self.lastAccessibilityFocused
                    self.publish(
                        keyboardFocused || self.sidebarMenuTracking
                            || self.lastAccessibilityFocused)
                }
            })
        observations.append(
            notificationCenter.addObserver(
                forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.sidebarMenuTracking = false
                    self.refresh(
                        includeAccessibilityFocus: self.isAccessibilityRefreshRelevant())
                }
            })
    }

    private var keyboardFocused: Bool {
        guard let root = sidebarRoot, let responder = root.window?.firstResponder as? NSView else {
            return false
        }
        let owner = Self.keyboardFocusOwner(for: responder)
        return owner === root || owner.isDescendant(of: root)
    }

    static func keyboardFocusOwner(for responder: NSView) -> NSView {
        if let fieldEditor = responder as? NSTextView,
            fieldEditor.isFieldEditor,
            let owner = fieldEditor.delegate as? NSView
        {
            return owner
        }
        return responder
    }

    private var accessibilityFocused: Bool {
        containsAccessibilityElement(focusedAccessibilityElement())
    }

    private func refresh(includeAccessibilityFocus: Bool = true) {
        guard !isDetached else { return }
        if includeAccessibilityFocus {
            lastAccessibilityFocused = accessibilityFocused
        }
        publish(
            keyboardFocused || sidebarMenuTracking
                || lastAccessibilityFocused)
    }

    private func clearForWindowLoss() {
        guard !isDetached else { return }
        sidebarMenuTracking = false
        lastAccessibilityFocused = false
        if lastActive {
            lastActive = false
            onActiveChange?(false)
        }
    }

    private func publish(_ active: Bool) {
        guard active != lastActive else { return }
        lastActive = active
        onActiveChange?(active)
    }

    func containsAccessibilityElement(_ element: Any?) -> Bool {
        guard let root = sidebarRoot else { return false }
        return Self.containsAccessibilityElement(element, in: root)
    }

    /// Climb the accessibility-parent chain (cycle-guarded) to the first NSView.
    static func accessibilityAncestorView(of element: Any?) -> NSView? {
        var current: Any? = element
        var visited: Set<ObjectIdentifier> = []
        while let candidate = current,
            visited.insert(ObjectIdentifier(candidate as AnyObject)).inserted
        {
            if let view = candidate as? NSView { return view }
            current = (candidate as? NSAccessibilityProtocol)?.accessibilityParent()
        }
        return nil
    }

    static func containsAccessibilityElement(_ element: Any?, in root: NSView) -> Bool {
        guard var current = element else { return false }
        var visited: Set<ObjectIdentifier> = []
        while visited.insert(ObjectIdentifier(current as AnyObject)).inserted {
            if let view = current as? NSView,
                view === root || view.isDescendant(of: root)
            {
                return true
            }
            guard let object = current as? NSAccessibilityProtocol,
                let parent = object.accessibilityParent()
            else { return false }
            if let parentView = parent as? NSView, parentView === root { return true }
            current = parent
        }
        return false
    }
}
