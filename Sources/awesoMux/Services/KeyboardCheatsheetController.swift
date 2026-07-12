import AppKit
import AwesoMuxConfig
import Observation
import SwiftUI

enum KeyboardCheatsheetLayout {
    static let defaultSize = CGSize(width: 860, height: 630)
    static let inset: CGFloat = 16

    static func resolvedSize(
        desired: CGSize = defaultSize,
        screenFrame: CGRect?
    ) -> CGSize {
        guard let screenFrame else { return desired }
        return CGSize(
            width: min(desired.width, max(0, screenFrame.width - inset * 2)),
            height: min(desired.height, max(0, screenFrame.height - inset * 2))
        )
    }

    static func origin(
        panelSize: CGSize,
        referenceFrame: CGRect?,
        screenFrame: CGRect?
    ) -> CGPoint? {
        guard let screenFrame else { return nil }
        let reference = referenceFrame ?? screenFrame
        let unclamped = CGPoint(
            x: reference.midX - panelSize.width / 2,
            y: reference.midY - panelSize.height / 2
        )
        let minX = screenFrame.minX + inset
        let maxX = max(minX, screenFrame.maxX - panelSize.width - inset)
        let minY = screenFrame.minY + inset
        let maxY = max(minY, screenFrame.maxY - panelSize.height - inset)
        return CGPoint(
            x: min(max(unclamped.x, minX), maxX),
            y: min(max(unclamped.y, minY), maxY)
        )
    }
}

@MainActor
@Observable
final class KeyboardCheatsheetController {
    typealias ShortcutRunner = @MainActor (String) -> Bool

    @ObservationIgnored private var panel: FloatingSwiftUIPanelWindow?
    @ObservationIgnored private var isDismissing = false
    @ObservationIgnored private var model = KeyboardCheatsheetModel(
        sections: KeyboardShortcutCatalog.settingsSections
    )
    @ObservationIgnored private var canRunShortcut: ShortcutRunner?
    @ObservationIgnored private var runShortcut: ShortcutRunner?
    // Set by the app so this floating-panel root carries the appearance bridge
    // (accent, glow, UI font, text scale) — otherwise it hosts a detached
    // SwiftUI tree that wouldn't scale with the text-size setting.
    @ObservationIgnored var appSettingsStore: AppSettingsStore?

    private(set) var isVisible = false

    func toggle(
        relativeTo parentWindow: NSWindow?,
        canRunShortcut: @escaping ShortcutRunner,
        runShortcut: @escaping ShortcutRunner
    ) {
        if isVisible {
            dismiss()
        } else {
            show(
                relativeTo: parentWindow,
                canRunShortcut: canRunShortcut,
                runShortcut: runShortcut
            )
        }
    }

    func show(
        relativeTo parentWindow: NSWindow?,
        canRunShortcut: @escaping ShortcutRunner,
        runShortcut: @escaping ShortcutRunner
    ) {
        let panel = panel ?? makePanel()
        model.reset()
        self.canRunShortcut = canRunShortcut
        self.runShortcut = runShortcut
        self.panel = panel
        panel.hostSwiftUIContent(makeRootView())
        configurePanelHandlers(panel)
        position(panel, relativeTo: resolveAnchorWindow(preferred: parentWindow))
        panel.presentAndFocus(focusHostedContent: false)
        isVisible = true
    }

    func dismiss() {
        guard !isDismissing else {
            return
        }

        guard let panel else {
            isVisible = false
            return
        }

        isDismissing = true
        isVisible = false
        panel.orderOut(nil)
        isDismissing = false
    }

    func hideIfKeyWindow() -> Bool {
        guard isVisible, panel?.isKeyWindow == true else {
            return false
        }
        dismiss()
        return true
    }

    private func makePanel() -> FloatingSwiftUIPanelWindow {
        let panel = FloatingSwiftUIPanelWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultPanelSize()),
            backing: .buffered,
            defer: false
        )
        panel.title = "Keyboard Shortcuts"
        panel.setAccessibilityLabel("Keyboard Shortcuts")
        panel.hostSwiftUIContent(makeRootView())
        return panel
    }

    @ViewBuilder
    private func makeRootView() -> some View {
        let root = KeyboardCheatsheetView(
            model: model,
            onRunSelected: { [weak self] in self?.runSelectedShortcut() },
            onRunEntry: { [weak self] in self?.runShortcut(id: $0) },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        if let appSettingsStore {
            root.appearanceBridge(appSettingsStore)
        } else {
            root
        }
    }

    private func configurePanelHandlers(_ panel: FloatingSwiftUIPanelWindow) {
        panel.onDismiss = { [weak self] in
            self?.dismiss()
        }
        panel.handlesKeyEvent = { [weak self, weak panel] event in
            if FloatingPanelEventPolicy.isDismissChord(
                type: event.type,
                keyCode: event.keyCode,
                isARepeat: event.isARepeat,
                modifiers: event.modifierFlags
            ) || FloatingPanelEventPolicy.isCloseChord(event) {
                self?.dismiss()
                return true
            }

            if KeyboardCheatsheetShortcut.matches(event) {
                self?.dismiss()
                return true
            }

            if KeyboardCheatsheetCopyCommand.matches(event, firstResponder: panel?.firstResponder) {
                self?.copySelectedShortcut()
                return true
            }

            if let command = KeyboardCheatsheetSearchCommand.command(
                for: event,
                firstResponder: panel?.firstResponder
            ) {
                switch command {
                case .move(let delta):
                    self?.model.moveSelection(by: delta)
                case .runSelected:
                    self?.runSelectedShortcut()
                case .dismiss:
                    self?.dismiss()
                }
                return true
            }

            if KeyboardCheatsheetShortcut.shouldDismissPanelForUnhandledKey(
                event,
                firstResponder: panel?.firstResponder
            ) {
                self?.dismiss()
                return true
            }

            return false
        }
    }

    private func copySelectedShortcut() {
        guard let copyText = model.selectedShortcutCopyText else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
    }

    private func runSelectedShortcut() {
        guard let selectedEntryID = model.selectedEntryID,
              runShortcut(id: selectedEntryID) else {
            return
        }
    }

    @discardableResult
    private func runShortcut(id commandID: KeyboardShortcutEntry.ID) -> Bool {
        guard canRunShortcut?(commandID) == true else {
            return false
        }

        dismiss()
        DispatchQueue.main.async { [weak self] in
            _ = self?.runShortcut?(commandID)
        }
        return true
    }

    private func position(_ panel: FloatingSwiftUIPanelWindow, relativeTo anchor: NSWindow?) {
        let visibleFrame = anchor?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let size = KeyboardCheatsheetLayout.resolvedSize(screenFrame: visibleFrame)
        panel.setFixedContentSize(size)
        if let origin = KeyboardCheatsheetLayout.origin(
            panelSize: size,
            referenceFrame: anchor?.frame,
            screenFrame: visibleFrame
        ) {
            panel.setFrameOrigin(origin)
        }
    }

    private func resolveAnchorWindow(preferred: NSWindow?) -> NSWindow? {
        if let preferred {
            return preferred
        }
        return NSApp.mainWindow ?? NSApp.keyWindow
    }

    private static func defaultPanelSize() -> CGSize {
        KeyboardCheatsheetLayout.defaultSize
    }
}
