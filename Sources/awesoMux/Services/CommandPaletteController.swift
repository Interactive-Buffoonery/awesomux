import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import Observation
import SwiftUI

enum CommandPaletteLayout {
    static let defaultSize = CGSize(width: 620, height: 430)
    static let inset: CGFloat = 16

    /// Clamp the desired panel size to the visible frame (minus insets) so the
    /// palette stays fully on-screen on small displays, Split View, or Stage
    /// Manager. Returns `defaultSize` unchanged when there's room.
    static func resolvedSize(
        desired: CGSize = defaultSize,
        screenFrame: CGRect?
    ) -> CGSize {
        guard let screenFrame else { return desired }
        let maxWidth = max(0, screenFrame.width - inset * 2)
        let maxHeight = max(0, screenFrame.height - inset * 2)
        return CGSize(
            width: min(desired.width, maxWidth),
            height: min(desired.height, maxHeight)
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

    /// Clamp an already-known origin (e.g. a remembered drag position) back into
    /// the visible frame so a remembered spot on a now-disconnected display
    /// doesn't open the palette offscreen.
    static func clampOrigin(
        _ origin: CGPoint,
        panelSize: CGSize,
        screenFrame: CGRect?
    ) -> CGPoint {
        guard let screenFrame else { return origin }
        let minX = screenFrame.minX + inset
        let maxX = max(minX, screenFrame.maxX - panelSize.width - inset)
        let minY = screenFrame.minY + inset
        let maxY = max(minY, screenFrame.maxY - panelSize.height - inset)
        return CGPoint(
            x: min(max(origin.x, minX), maxX),
            y: min(max(origin.y, minY), maxY)
        )
    }
}

@MainActor
@Observable
final class CommandPaletteController {
    @ObservationIgnored private var panel: FloatingSwiftUIPanelWindow?
    @ObservationIgnored private let focusState = CommandPaletteFocusState()
    @ObservationIgnored private var isDismissing = false
    @ObservationIgnored private let positionStore: PalettePositionStore
    @ObservationIgnored private weak var lastAnchorWindow: NSWindow?
    /// The origin we last set programmatically (center / remembered / reclamp).
    /// At dismiss time, an origin that differs from this means something moved
    /// the panel outside our placement code. This avoids turning a never-touched
    /// centered origin into a sticky "custom" position.
    @ObservationIgnored private var lastProgrammaticOrigin: CGPoint?
    // Set by the app so this floating-panel root carries the appearance bridge
    // (accent, glow, UI font, text scale) — otherwise it hosts a detached
    // SwiftUI tree that wouldn't scale with the text-size setting.
    @ObservationIgnored var appSettingsStore: AppSettingsStore?

    private(set) var isVisible = false

    init(positionStore: PalettePositionStore = PalettePositionStore()) {
        self.positionStore = positionStore
    }

    func toggle(relativeTo parentWindow: NSWindow?, presenter: PalettePresenter) {
        if isVisible {
            dismiss()
        } else {
            show(relativeTo: parentWindow, presenter: presenter)
        }
    }

    func show(relativeTo parentWindow: NSWindow?, presenter: PalettePresenter) {
        let isFreshPanel = (panel == nil)
        let panel = panel ?? makePanel(presenter: presenter)
        self.panel = panel

        // Always rebind the root view so each summon reflects current session
        // and command state (the panel itself is reused across opens).
        panel.hostSwiftUIContent(makeRootView(presenter: presenter))
        configurePanelHandlers(panel, presenter: presenter)
        panel.activateAppIfNeeded()

        // Resolve the anchor window *after* activation, when mainWindow/keyWindow
        // are populated; remember it so the re-center command can reuse it.
        let anchor = resolveAnchorWindow(preferred: parentWindow)
        lastAnchorWindow = anchor

        if isFreshPanel {
            // Center on first creation (or restore a remembered custom origin).
            position(panel, relativeTo: anchor, useRememberedOrigin: true)
        } else {
            // Panel kept alive across dismiss retains its frame, but the screen
            // it lived on may have shrunk/disconnected since — pull it back into
            // the current visible frame without re-centering.
            reclamp(panel, relativeTo: anchor)
        }

        panel.presentAndFocus(focusHostedContent: false)
        isVisible = true
        postSummonAnnouncement()
    }

    func dismiss() {
        guard !isDismissing else {
            return
        }

        guard let panel else {
            focusState.isKeyWindow = false
            isVisible = false
            return
        }

        isDismissing = true
        isVisible = false
        focusState.isKeyWindow = false
        // Persist the origin only if the panel moved outside our placement code
        // (its origin drifted from the last spot we set it). Saving unconditionally
        // would turn the first centered origin into a sticky "custom" position
        // and defeat "center first, then preserve custom placement". In-session position
        // survives regardless because we keep the panel instance — only
        // orderOut, never tear down. `orderOut` synchronously triggers
        // resignKey → onDismiss, re-entering here, absorbed by isDismissing.
        if let lastProgrammaticOrigin, panel.frame.origin != lastProgrammaticOrigin {
            positionStore.save(panel.frame.origin)
        }
        panel.orderOut(nil)
        isDismissing = false
    }

    /// "Reset Palette Position" — forget the remembered origin and re-center on
    /// the anchor window, then present the palette centered. Invoked from the
    /// palette itself, which dismisses on command-run, so this re-shows to give
    /// the Raycast-style "snaps back to center" feel.
    func recenter() {
        positionStore.clear()
        guard let panel else { return }
        panel.activateAppIfNeeded()
        let anchor = resolveAnchorWindow(preferred: lastAnchorWindow)
        lastAnchorWindow = anchor
        position(panel, relativeTo: anchor, useRememberedOrigin: false)
        panel.presentAndFocus(focusHostedContent: false)
        isVisible = true
        // The palette dismisses then re-shows centered; announce it so VoiceOver
        // users get feedback that the reset happened.
        postAnnouncement("Command palette centered.", priority: .high)
    }

    func hideIfKeyWindow() -> Bool {
        guard isVisible, focusState.isKeyWindow else {
            return false
        }
        dismiss()
        return true
    }

    @ViewBuilder
    private func makeRootView(presenter: PalettePresenter) -> some View {
        let root = CommandPaletteView(
            presenter: presenter,
            focusState: focusState,
            onDismiss: { [weak self] in
                self?.dismiss()
            },
            onAnnounce: { [weak self] message in
                self?.postAnnouncement(message)
            }
        )
        if let appSettingsStore {
            root.appearanceBridge(appSettingsStore)
        } else {
            root
        }
    }

    private func makePanel(presenter: PalettePresenter) -> FloatingSwiftUIPanelWindow {
        let panel = FloatingSwiftUIPanelWindow(
            contentRect: NSRect(origin: .zero, size: CommandPaletteLayout.defaultSize),
            backing: .buffered,
            defer: false
        )
        panel.hostSwiftUIContent(makeRootView(presenter: presenter))
        panel.title = "Command Palette"
        panel.setAccessibilityLabel("Command Palette")
        return panel
    }

    private func configurePanelHandlers(
        _ panel: FloatingSwiftUIPanelWindow,
        presenter: PalettePresenter
    ) {
        panel.onDismiss = { [weak self] in
            self?.dismiss()
        }
        panel.onKeyStateChanged = { [weak self] isKeyWindow in
            self?.focusState.isKeyWindow = isKeyWindow
        }
        panel.onModifierFlagsChanged = { [weak self] flags in
            self?.focusState.modifierFlags = flags
        }
        panel.handlesKeyEvent = { [weak self, weak panel] event in
            if FloatingPanelEventPolicy.isDismissChord(
                type: event.type,
                keyCode: event.keyCode,
                isARepeat: event.isARepeat,
                modifiers: event.modifierFlags
            ) || FloatingPanelEventPolicy.isCloseChord(event) {
                panel?.onDismiss?()
                return true
            }

            if let command = CommandPaletteSearchCommand.modifiedReturnCommand(for: event) {
                return self?.performPaletteCommand(command, presenter: presenter) ?? false
            }

            if FloatingPanelEventPolicy.isGlobalWorkspaceJumpChord(event) {
                return true
            }

            return false
        }
    }

    private func performPaletteCommand(
        _ command: CommandPaletteSearchCommand,
        presenter: PalettePresenter
    ) -> Bool {
        switch command {
        case .submit(let surface):
            guard let result = presenter.selectedResult,
                  presenter.canPerform(result) else {
                return false
            }
            dismiss()
            DispatchQueue.main.async {
                presenter.perform(result, surface: surface)
            }
            return true
        case .move, .dismiss:
            return false
        }
    }

    /// Resolve the window to center over. `mainWindow`/`keyWindow` can be nil
    /// during activation, or resolve to the palette panel itself; fall back to
    /// the first real, visible, main-capable app window before giving up to the
    /// screen.
    private func resolveAnchorWindow(preferred: NSWindow?) -> NSWindow? {
        if let preferred, preferred.canBecomeMain, !(preferred is NSPanel) {
            return preferred
        }
        return NSApp.mainWindow
            ?? NSApp.windows.first { window in
                window.isVisible && window.canBecomeMain && !(window is NSPanel)
            }
            ?? NSApp.keyWindow
    }

    private func position(
        _ panel: FloatingSwiftUIPanelWindow,
        relativeTo anchorWindow: NSWindow?,
        useRememberedOrigin: Bool
    ) {
        let screenFrame = anchorWindow?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
        let referenceFrame = anchorWindow?.frame ?? screenFrame

        let size = CommandPaletteLayout.resolvedSize(screenFrame: screenFrame)
        panel.setFixedContentSize(size)

        let target: CGPoint?
        if useRememberedOrigin, let remembered = positionStore.load() {
            target = CommandPaletteLayout.clampOrigin(
                remembered,
                panelSize: size,
                screenFrame: screenFrame
            )
        } else {
            target = CommandPaletteLayout.origin(
                panelSize: size,
                referenceFrame: referenceFrame,
                screenFrame: screenFrame
            )
        }

        if let target {
            panel.setFrameOrigin(target)
        } else {
            panel.center()
        }
        lastProgrammaticOrigin = panel.frame.origin
        panel.invalidateShadow()
    }

    /// Re-fit an already-positioned (kept-alive) panel into the current visible
    /// frame without re-centering, so a remembered/custom spot survives a
    /// display or Split-View change instead of opening offscreen or oversized.
    private func reclamp(
        _ panel: FloatingSwiftUIPanelWindow,
        relativeTo anchorWindow: NSWindow?
    ) {
        let screenFrame = anchorWindow?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
        let size = CommandPaletteLayout.resolvedSize(screenFrame: screenFrame)
        panel.setFixedContentSize(size)
        let clamped = CommandPaletteLayout.clampOrigin(
            panel.frame.origin,
            panelSize: size,
            screenFrame: screenFrame
        )
        panel.setFrameOrigin(clamped)
        // A clamp that nudges the frame is a programmatic move, not a custom move —
        // baseline it so dismiss() doesn't mistake it for one.
        lastProgrammaticOrigin = panel.frame.origin
        panel.invalidateShadow()
    }

    private func postSummonAnnouncement() {
        postAnnouncement(
            "Command palette. Type to search workspaces and actions. Press Escape to dismiss.",
            priority: .high
        )
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
final class CommandPaletteFocusState {
    var isKeyWindow = false
    var modifierFlags: NSEvent.ModifierFlags = []

    var quickRunCommitSurface: PaletteQuickRunCommitSurface {
        Self.quickRunCommitSurface(for: modifierFlags)
    }

    nonisolated static func quickRunCommitSurface(for flags: NSEvent.ModifierFlags) -> PaletteQuickRunCommitSurface {
        let normalized = flags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function])
        if normalized.contains(.command), normalized.contains(.shift) {
            return .newTab
        }
        if normalized.contains(.command) {
            return .floatingPanel
        }
        return .toast
    }
}
