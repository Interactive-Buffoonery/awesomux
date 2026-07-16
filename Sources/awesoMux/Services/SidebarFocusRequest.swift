import AppKit
import os

extension Notification.Name {
    static let awesoMuxFocusSidebarRequested = Notification.Name(
        "com.interactivebuffoonery.awesomux.focusSidebarRequested"
    )

    static let awesoMuxToggleSidebarWidthRequested = Notification.Name(
        "com.interactivebuffoonery.awesomux.toggleSidebarWidthRequested"
    )
    static let awesoMuxToggleSidebarVisibilityRequested = Notification.Name(
        "com.interactivebuffoonery.awesomux.toggleSidebarVisibilityRequested"
    )
}

@MainActor
struct EmptyWorkspaceAccessibilityFocusTarget {
    let isVisible: () -> Bool
    let setAccessibilityFocused: (Bool) -> Void
    let isAccessibilityFocused: () -> Bool
}

@MainActor
enum EmptyWorkspaceAccessibilityFocusHandoff {
    static let targetIdentifier =
        "com.interactivebuffoonery.awesomux.emptyWorkspace.newWorkspace"

    static func focus(
        _ request: SidebarFocusHandoffRequest,
        in root: NSView?
    ) -> Bool {
        guard request.requiresAccessibilityFocus else { return false }
        return focus(in: root)
    }

    static func focus(in root: NSView?) -> Bool {
        focus(in: root) { root in
            guard let root, let element = target(in: root) else { return nil }
            return EmptyWorkspaceAccessibilityFocusTarget(
                isVisible: { isVisible(element, within: root) },
                setAccessibilityFocused: { element.setAccessibilityFocused($0) },
                isAccessibilityFocused: { element.isAccessibilityFocused() }
            )
        }
    }

    static func focus(
        in root: NSView?,
        resolve: (NSView?) -> EmptyWorkspaceAccessibilityFocusTarget?
    ) -> Bool {
        guard let target = resolve(root), target.isVisible() else { return false }
        target.setAccessibilityFocused(true)
        return target.isAccessibilityFocused()
    }

    static func target(in root: NSView?) -> NSAccessibilityProtocol? {
        guard let root else { return nil }
        var queue: [Any] = [root]
        var visited: Set<ObjectIdentifier> = []
        var nextIndex = 0

        while nextIndex < queue.count {
            let candidate = queue[nextIndex]
            nextIndex += 1

            let identity = ObjectIdentifier(candidate as AnyObject)
            guard visited.insert(identity).inserted else { continue }

            if let element = candidate as? NSAccessibilityProtocol {
                if element.accessibilityIdentifier() == targetIdentifier {
                    if isVisible(element, within: root) { return element }
                }
                queue.append(contentsOf: element.accessibilityChildren() ?? [])
            }
            if let view = candidate as? NSView {
                queue.append(contentsOf: view.subviews)
            }
        }
        return nil
    }

    private static func isVisible(
        _ element: NSAccessibilityProtocol,
        within root: NSView
    ) -> Bool {
        guard !element.accessibilityFrame().isEmpty else { return false }

        guard let view = SidebarInteractionMonitor.accessibilityAncestorView(of: element),
            view === root || view.isDescendant(of: root)
        else { return false }
        return isVisible(view, within: root)
    }

    private static func isVisible(_ view: NSView, within root: NSView) -> Bool {
        guard view.window != nil else { return false }
        var current: NSView? = view
        while let ancestor = current {
            if ancestor.isHidden || ancestor.alphaValue == 0 { return false }
            current = ancestor.superview
        }

        let clippedBounds = view.bounds.intersection(view.visibleRect)
        guard !clippedBounds.isEmpty else { return false }
        let frameInRoot = view.convert(clippedBounds, to: root)
        let rootVisibleBounds = root.bounds.intersection(root.visibleRect)
        return !frameInRoot.intersection(rootVisibleBounds).isEmpty
    }
}

@MainActor
enum SidebarFocusShortcut {
    static func matches(_ event: NSEvent) -> Bool {
        let matched = isFocusSidebarChord(event) && !event.isARepeat
        ShortcutDiagnostics.logMatcher(event: event, matched: matched)
        return matched
    }

    static func isRepeat(ofFocusSidebarChord event: NSEvent) -> Bool {
        isFocusSidebarChord(event) && event.isARepeat
    }

    private static func isFocusSidebarChord(_ event: NSEvent) -> Bool {
        CurrentKeyboardShortcuts.binding(id: KeyboardShortcutCatalog.focusSidebar.id)?.matches(event) == true
    }
}

@MainActor
enum SidebarWidthToggleShortcut {
    static func matches(_ event: NSEvent) -> Bool {
        let matched = isToggleSidebarWidthChord(event) && !event.isARepeat
        ShortcutDiagnostics.logMatcher(event: event, matched: matched)
        return matched
    }

    static func isRepeat(ofToggleSidebarWidthChord event: NSEvent) -> Bool {
        isToggleSidebarWidthChord(event) && event.isARepeat
    }

    private static func isToggleSidebarWidthChord(_ event: NSEvent) -> Bool {
        CurrentKeyboardShortcuts.binding(id: KeyboardShortcutCatalog.toggleSidebarWidth.id)?.matches(event) == true
    }
}

@MainActor
enum SidebarVisibilityToggleShortcut {
    static func matches(_ event: NSEvent) -> Bool {
        let matched = isToggleSidebarVisibilityChord(event) && !event.isARepeat
        ShortcutDiagnostics.logMatcher(event: event, matched: matched)
        return matched
    }

    static func isRepeat(ofToggleSidebarVisibilityChord event: NSEvent) -> Bool {
        isToggleSidebarVisibilityChord(event) && event.isARepeat
    }

    private static func isToggleSidebarVisibilityChord(_ event: NSEvent) -> Bool {
        CurrentKeyboardShortcuts.binding(id: KeyboardShortcutCatalog.toggleSidebarVisibility.id)?.matches(event) == true
    }
}

enum ShortcutDiagnostics {
    private static let logger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "ShortcutDiagnostics"
    )

    // Resolved once: `sendEvent` evaluates this on every event, and the
    // enabled state can't meaningfully change mid-process because diagnostics
    // are injected via a process-scoped environment variable before launch.
    // Computing it per call would rebuild the environment dictionary on the
    // hottest path in the app.
    static let isEnabled: Bool = {
        ProcessInfo.processInfo.environment["AWESOMUX_SHORTCUT_DIAGNOSTICS"] == "1"
    }()

    static func logSendEvent(_ event: NSEvent) {
        guard event.type == .keyDown, isEnabled else { return }

        // `chars` is the user's literal typed character. In a terminal app that
        // can be a password or key, so it's redacted in shipped logs; keyCode +
        // modifiers are enough to identify the chord. A developer can reveal it
        // with an explicit `log config` redaction override.
        logger.info(
            """
            shortcut-diagnostics stage=sendEvent \
            keyCode=\(event.keyCode, privacy: .public) \
            modifiers=\(event.modifierFlags.rawValue, privacy: .public) \
            chars=\(event.charactersIgnoringModifiers ?? "", privacy: .private)
            """
        )
    }

    static func logMatcher(event: NSEvent, matched: Bool) {
        guard event.type == .keyDown, isEnabled else { return }

        logger.info(
            """
            shortcut-diagnostics stage=matcher \
            matched=\(matched, privacy: .public) \
            keyCode=\(event.keyCode, privacy: .public) \
            modifiers=\(event.modifierFlags.rawValue, privacy: .public) \
            chars=\(event.charactersIgnoringModifiers ?? "", privacy: .private) \
            repeat=\(event.isARepeat, privacy: .public)
            """
        )
    }

    static func log(_ message: String) {
        guard isEnabled else { return }

        logger.info("shortcut-diagnostics \(message, privacy: .public)")
    }
}
