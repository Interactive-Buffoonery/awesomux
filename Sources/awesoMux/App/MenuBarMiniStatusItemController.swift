import AppKit
import AwesoMuxConfig
import DesignSystem
import SwiftUI

enum MenuBarMiniStatusPresentation {
    static func shouldShow(
        visibility: GeneralConfig.MenuBarVisibility,
        hasWorkspaceNeedingInput: Bool
    ) -> Bool {
        switch visibility {
        case .never:
            false
        case .needsInput:
            hasWorkspaceNeedingInput
        case .always:
            true
        }
    }
}

@MainActor
final class MenuBarMiniStatusItemController: NSObject {
    private let statusBar: NSStatusBar
    private let menuProvider: () -> NSMenu?
    private var statusItem: NSStatusItem?
    private var attentionBadgeView: MenuBarAttentionBadgeView?

    init(
        statusBar: NSStatusBar = .system,
        menuProvider: @escaping () -> NSMenu?
    ) {
        self.statusBar = statusBar
        self.menuProvider = menuProvider
    }

    func update(
        visibility: GeneralConfig.MenuBarVisibility,
        hasWorkspaceNeedingInput: Bool
    ) {
        guard MenuBarMiniStatusPresentation.shouldShow(
                visibility: visibility,
            hasWorkspaceNeedingInput: hasWorkspaceNeedingInput
        ) else {
            removeStatusItem()
            return
        }

        configureStatusItem(
            ensureStatusItem(),
            showsAttentionBadge: hasWorkspaceNeedingInput
        )
    }

    private func ensureStatusItem() -> NSStatusItem {
        if let statusItem {
            return statusItem
        }
        let item = statusBar.statusItem(withLength: 20)
        statusItem = item
        return item
    }

    private func configureStatusItem(
        _ item: NSStatusItem,
        showsAttentionBadge: Bool
    ) {
        guard let button = item.button else { return }
        button.image = nil
        button.title = Self.statusTitle
        button.font = .monospacedSystemFont(ofSize: 13.5, weight: .bold)
        button.alignment = .center
        button.target = self
        button.action = #selector(showStatusItemMenu(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateAttentionBadge(on: button, isVisible: showsAttentionBadge)
        let label =
            showsAttentionBadge
            ? String(
                localized: "awesoMux workspace needs input",
                comment: "Tooltip and accessibility label for the menu bar item when any workspace needs input."
            )
            : String(localized: "awesoMux", comment: "Tooltip and accessibility label for the idle menu bar item.")
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        attentionBadgeView?.removeFromSuperview()
        attentionBadgeView = nil
        statusBar.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func updateAttentionBadge(
        on button: NSStatusBarButton,
        isVisible: Bool
    ) {
        guard isVisible else {
            attentionBadgeView?.isHidden = true
            return
        }

        if let attentionBadgeView {
            attentionBadgeView.isHidden = false
            attentionBadgeView.needsDisplay = true
            return
        }

        let badgeView = MenuBarAttentionBadgeView()
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(badgeView)
        NSLayoutConstraint.activate([
            badgeView.widthAnchor.constraint(equalToConstant: 4.5),
            badgeView.heightAnchor.constraint(equalToConstant: 4.5),
            badgeView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
            badgeView.topAnchor.constraint(equalTo: button.topAnchor, constant: 2),
        ])
        attentionBadgeView = badgeView
    }

    @objc
    private func showStatusItemMenu(_: NSStatusBarButton) {
        showContextMenu()
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

    static let statusTitle = Brandmark.glyph
}

private final class MenuBarAttentionBadgeView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(Color.aw.accent).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
