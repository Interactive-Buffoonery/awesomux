import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import Observation
import SwiftUI

/// Floating-panel presenter for the Session Manager: a borderless-look `NSPanel`
/// hosting the SwiftUI panel, Esc / Cmd-W / click-away dismiss, and a11y
/// announcements posted against the panel element (announcements on a non-key
/// window are otherwise dropped).
///
/// Daemon polling is scoped to panel-open: `show` starts it, `dismiss` stops it.
/// The panel instance is kept alive across dismiss (orderOut, not close) so its
/// position survives a re-summon.
@MainActor
@Observable
final class SessionManagerController {
    @ObservationIgnored private var panel: FloatingSwiftUIPanelWindow?
    @ObservationIgnored private let focusState = SessionManagerFocusState()
    @ObservationIgnored private var isDismissing = false
    @ObservationIgnored private weak var model: SessionManagerModel?
    @ObservationIgnored private var onJump: (TerminalSessionID) -> Void = { _ in }
    // Set by the app so this floating-panel root can carry the appearance
    // bridge (accent, glow, UI font, text scale). Without it the panel hosts a
    // detached SwiftUI tree that wouldn't scale with the text-size setting.
    @ObservationIgnored var appSettingsStore: AppSettingsStore?

    private(set) var isVisible = false

    static let defaultSize = CGSize(width: 860, height: 600)
    private static let screenInset: CGFloat = 16

    func toggle(
        model: SessionManagerModel,
        relativeTo parentWindow: NSWindow?,
        onJump: @escaping (TerminalSessionID) -> Void
    ) {
        if isVisible {
            dismiss()
        } else {
            show(model: model, relativeTo: parentWindow, onJump: onJump)
        }
    }

    func show(
        model: SessionManagerModel,
        relativeTo parentWindow: NSWindow?,
        onJump: @escaping (TerminalSessionID) -> Void
    ) {
        self.model = model
        self.onJump = onJump
        // Inject the a11y announce sink so model snapshot diffs are spoken
        // against this panel (a non-key window's announcements are dropped).
        model.announce = { [weak self] message in
            self?.postAnnouncement(message)
        }

        let panel = panel ?? makePanel(model: model)
        self.panel = panel
        panel.hostSwiftUIContent(makeRootView(model: model))

        position(panel, relativeTo: parentWindow)
        panel.presentAndFocus()
        isVisible = true
        model.startPolling()
        postAnnouncement(
            "Session Manager. Background sessions grouped by lifecycle. Navigate to a session and activate Pin or Reap. Press Escape to dismiss.",
            priority: .high
        )
    }

    func dismiss() {
        guard !isDismissing else { return }
        guard let panel else {
            focusState.isKeyWindow = false
            isVisible = false
            model?.stopPolling()
            return
        }
        isDismissing = true
        isVisible = false
        focusState.isKeyWindow = false
        model?.stopPolling()
        panel.orderOut(nil)
        isDismissing = false
    }

    func hideIfKeyWindow() -> Bool {
        guard isVisible, focusState.isKeyWindow else { return false }
        dismiss()
        return true
    }

    @ViewBuilder
    private func makeRootView(model: SessionManagerModel) -> some View {
        let root = SessionManagerPanel(
            model: model,
            focusState: focusState,
            onDismiss: { [weak self] in self?.dismiss() },
            onJump: { [weak self] id in
                self?.onJump(id)
                self?.dismiss()
            }
        )
        if let appSettingsStore {
            root.appearanceBridge(appSettingsStore)
        } else {
            root
        }
    }

    private func makePanel(model: SessionManagerModel) -> FloatingSwiftUIPanelWindow {
        let panel = FloatingSwiftUIPanelWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            backing: .buffered,
            defer: false
        )
        panel.hostSwiftUIContent(makeRootView(model: model))
        panel.title = "Session Manager"
        panel.setAccessibilityLabel("Session Manager")
        panel.onDismiss = { [weak self] in self?.dismiss() }
        panel.onKeyStateChanged = { [weak self] isKeyWindow in
            self?.focusState.isKeyWindow = isKeyWindow
        }
        panel.handlesKeyEvent = { [weak panel] event in
            if FloatingPanelEventPolicy.isDismissChord(
                type: event.type,
                keyCode: event.keyCode,
                isARepeat: event.isARepeat,
                modifiers: event.modifierFlags
            ) || FloatingPanelEventPolicy.isCloseChord(event) {
                panel?.onDismiss?()
                return true
            }

            if FloatingPanelEventPolicy.isGlobalWorkspaceJumpChord(event) {
                return true
            }

            return false
        }
        return panel
    }

    /// Center the panel over the anchor window, clamped to the visible frame so
    /// it stays on-screen on small displays / Split View.
    private func position(
        _ panel: FloatingSwiftUIPanelWindow,
        relativeTo anchorWindow: NSWindow?
    ) {
        let screenFrame = anchorWindow?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
        guard let screenFrame else {
            panel.center()
            return
        }
        let inset = Self.screenInset
        let size = CGSize(
            width: min(Self.defaultSize.width, max(0, screenFrame.width - inset * 2)),
            height: min(Self.defaultSize.height, max(0, screenFrame.height - inset * 2))
        )
        panel.setFixedContentSize(size)

        let reference = anchorWindow?.frame ?? screenFrame
        let unclampedX = reference.midX - size.width / 2
        let unclampedY = reference.midY - size.height / 2
        let minX = screenFrame.minX + inset
        let maxX = max(minX, screenFrame.maxX - size.width - inset)
        let minY = screenFrame.minY + inset
        let maxY = max(minY, screenFrame.maxY - size.height - inset)
        panel.setFrameOrigin(CGPoint(
            x: min(max(unclampedX, minX), maxX),
            y: min(max(unclampedY, minY), maxY)
        ))
        panel.invalidateShadow()
    }

    private func postAnnouncement(
        _ message: String,
        priority: NSAccessibilityPriorityLevel = .medium
    ) {
        guard let panel else { return }
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue
            ]
        )
    }
}

@MainActor
@Observable
final class SessionManagerFocusState {
    var isKeyWindow = false
}
