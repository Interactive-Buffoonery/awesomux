import AppKit
import DesignSystem
import SwiftUI

enum MenuBarMiniStatusPresentation {
    static func shouldShow(
        isEnabled: Bool,
        hasWorkspaceNeedingInput: Bool
    ) -> Bool {
        isEnabled && hasWorkspaceNeedingInput
    }
}

enum MenuBarMiniStatusClick {
    case primary
    case secondary

    static func resolve(
        eventType: NSEvent.EventType?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Self {
        if eventType == .rightMouseUp || modifierFlags.contains(.control) {
            return .secondary
        }
        return .primary
    }
}

@MainActor
final class MenuBarMiniStatusItemController: NSObject {
    private let statusBar: NSStatusBar
    private let primaryAction: () -> Void
    private let menuProvider: () -> NSMenu?
    private var statusItem: NSStatusItem?

    init(
        statusBar: NSStatusBar = .system,
        primaryAction: @escaping () -> Void,
        menuProvider: @escaping () -> NSMenu?
    ) {
        self.statusBar = statusBar
        self.primaryAction = primaryAction
        self.menuProvider = menuProvider
    }

    func update(
        isEnabled: Bool,
        hasWorkspaceNeedingInput: Bool
    ) {
        guard MenuBarMiniStatusPresentation.shouldShow(
            isEnabled: isEnabled,
            hasWorkspaceNeedingInput: hasWorkspaceNeedingInput
        ) else {
            removeStatusItem()
            return
        }

        configureStatusItem(ensureStatusItem())
    }

    private func ensureStatusItem() -> NSStatusItem {
        if let statusItem {
            return statusItem
        }
        let item = statusBar.statusItem(withLength: 18)
        statusItem = item
        return item
    }

    private func configureStatusItem(_ item: NSStatusItem) {
        guard let button = item.button else { return }
        button.image = Self.needsAttentionImage()
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = String(
            localized: "awesoMux workspace needs input",
            comment: "Tooltip for the menu bar mini-status item when any workspace needs input."
        )
        button.setAccessibilityLabel(String(
            localized: "awesoMux workspace needs input",
            comment: "Accessibility label for the menu bar mini-status item when any workspace needs input."
        ))
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        statusBar.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    @objc
    private func statusItemClicked(_ sender: NSStatusBarButton) {
        switch MenuBarMiniStatusClick.resolve(
            eventType: NSApp.currentEvent?.type,
            modifierFlags: NSApp.currentEvent?.modifierFlags ?? []
        ) {
        case .primary:
            primaryAction()
        case .secondary:
            showContextMenu()
        }
    }

    private func showContextMenu() {
        guard let menu = menuProvider() else {
            NSSound.beep()
            return
        }
        guard let button = statusItem?.button else {
            NSSound.beep()
            return
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.maxY + 4),
            in: button
        )
    }

    private static func needsAttentionImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let color = NSColor(Color.aw.status.needs)
            color.setFill()
            NSBezierPath(
                ovalIn: NSRect(
                    x: rect.midX - 3.5,
                    y: rect.midY - 3.5,
                    width: 7,
                    height: 7
                )
            ).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
