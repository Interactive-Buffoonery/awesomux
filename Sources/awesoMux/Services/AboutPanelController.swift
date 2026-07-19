import AppKit
import AwesoMuxConfig
import Observation
import SwiftUI

/// Floating-panel presenter for the About window, mirroring
/// `SessionManagerController`. The panel route exists because the SwiftUI
/// `Window` scene fought every placement attempt (`.defaultPosition(.center)`
/// ignored for this scene configuration; a deferred `NSWindow.center()` from a
/// view-attach callback overridden by the scene's own late placement pass —
/// the same race `PrimaryWindowFramePersistence` documents). A controller-owned
/// `NSPanel` sets its frame before ordering front, so placement is
/// deterministic: no scene machinery ever repositions it.
///
/// The panel is kept alive across dismiss (orderOut, not close) so its
/// position survives a re-summon within the session.
@MainActor
@Observable
final class AboutPanelController {
    @ObservationIgnored private var panel: FloatingSwiftUIPanelWindow?
    @ObservationIgnored private var isKeyWindow = false
    // Set by the app so this floating-panel root carries the appearance
    // bridge (accent, glow, UI font, text scale) — same contract as the
    // command palette / session manager controllers (INT-237/INT-367).
    @ObservationIgnored var appSettingsStore: AppSettingsStore?

    private(set) var isVisible = false

    private static let fallbackSize = CGSize(width: 360, height: 560)

    /// About-menu convention: invoking again fronts the existing panel
    /// rather than toggling it away.
    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.hostSwiftUIContent(makeRootView())

        if !isVisible {
            // Size to the SwiftUI ideal (fixed 360pt width; height tracks
            // content, so Dynamic Type growth is respected), then center —
            // BEFORE presenting, the ordering that makes panel placement
            // deterministic. Screen-centered per macOS About convention.
            let fitting = panel.contentViewController?.view.fittingSize ?? .zero
            let size =
                fitting.width > 0 && fitting.height > 0
                ? fitting : Self.fallbackSize
            panel.setFixedContentSize(size)
            panel.center()
        }
        panel.presentAndFocus()
        isVisible = true
    }

    func dismiss() {
        isVisible = false
        isKeyWindow = false
        panel?.orderOut(nil)
    }

    /// Cmd-W routing hook, checked by `closeActivePaneOrWindow` alongside the
    /// other floating-panel controllers.
    func hideIfKeyWindow() -> Bool {
        guard isVisible, isKeyWindow else { return false }
        dismiss()
        return true
    }

    @ViewBuilder
    private func makeRootView() -> some View {
        let root = AboutWindowView(onDismiss: { [weak self] in self?.dismiss() })
        if let appSettingsStore {
            root.appearanceBridge(appSettingsStore)
        } else {
            root
        }
    }

    private func makePanel() -> FloatingSwiftUIPanelWindow {
        let panel = FloatingSwiftUIPanelWindow(
            contentRect: NSRect(origin: .zero, size: Self.fallbackSize),
            backing: .buffered,
            defer: false
        )
        panel.title = "About awesoMux"
        panel.setAccessibilityLabel("About awesoMux")
        panel.awesoMuxWindowRole = .about
        panel.onDismiss = { [weak self] in self?.dismiss() }
        panel.onKeyStateChanged = { [weak self] isKey in
            self?.isKeyWindow = isKey
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
            return false
        }
        return panel
    }
}
