import AppKit
import AwesoMuxConfig
import Foundation
import Observation
import SwiftUI

/// Whether the welcome tour should present itself unprompted.
///
/// `EmptyWorkspaceMode` alone cannot answer this: its own comment calls an
/// empty tree "cold launch / all-closed", closing the last group returns to
/// that state, and workspace restore being off makes it permanent. Install
/// age is a separate input.
enum FirstRunTourPolicy {
    static func shouldAutoPresent(
        hasSeenTour: Bool,
        hasPriorInstallEvidence: Bool,
        mode: EmptyWorkspaceMode
    ) -> Bool {
        guard !hasSeenTour, !hasPriorInstallEvidence else { return false }
        return mode == .firstLaunch
    }

    static func hasPriorInstallEvidence(
        snapshotExists: Bool,
        configDirectoryExists: Bool
    ) -> Bool {
        snapshotExists || configDirectoryExists
    }

    /// Written once, before the tour can ever evaluate. Without it an existing
    /// user upgrading into this build has the (false-by-default) flag and gets
    /// greeted as brand new.
    static func seedSeenFlagIfNeeded(
        defaults: UserDefaults = .standard,
        hasPriorInstallEvidence: Bool
    ) {
        guard hasPriorInstallEvidence else { return }
        defaults.set(true, forKey: SettingsKey.hasSeenFirstRunTour)
    }
}

/// Floating-panel presenter for the five-beat welcome tour, mirroring
/// `AboutPanelController`. The panel is kept alive across dismiss (orderOut,
/// not close) so a re-summon within the session resumes rather than restarts.
@MainActor
@Observable
final class FirstRunTourController {
    static let beatCount = 5
    /// Beat index (0-based) whose copy introduces notifications. The prime
    /// policy defers until the user has read it.
    static let notificationBeatIndex = 2

    @ObservationIgnored private var panel: FloatingSwiftUIPanelWindow?
    @ObservationIgnored private var isKeyWindow = false
    @ObservationIgnored private let defaults: UserDefaults
    // Set by the app so this floating-panel root carries the appearance
    // bridge (accent, glow, UI font, text scale) — same contract as the
    // command palette / About / cheatsheet controllers.
    @ObservationIgnored var appSettingsStore: AppSettingsStore?

    private(set) var isVisible = false
    private(set) var currentBeat = 0

    var hasReachedNotificationBeat: Bool { currentBeat >= Self.notificationBeatIndex }

    /// Placeholder pending Task 8: the real beats don't exist yet, so there is
    /// nothing to measure. `show()` falls back to this exactly the way
    /// `AboutPanelController` falls back when its fitting size is zero; Task 8
    /// replaces the zero-fitting-size branch with a tallest-beat measurement
    /// (`maximumBeatFittingSize`) once the beat views exist.
    private static let fallbackSize = CGSize(width: 480, height: 420)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Re-summoning resumes rather than restarting: `currentBeat` is
    /// deliberately left untouched here.
    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel

        if !isVisible {
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

    func advance() { currentBeat = min(currentBeat + 1, Self.beatCount - 1) }
    func retreat() { currentBeat = max(currentBeat - 1, 0) }

    /// Esc, Cmd-W, the close control, or finishing beat five. Only this path
    /// silences the tour — a tour that marked itself seen because the user
    /// clicked its own "Set up agents" button would end onboarding at beat
    /// three, permanently.
    func dismissByUser() {
        defaults.set(true, forKey: SettingsKey.hasSeenFirstRunTour)
        isVisible = false
        isKeyWindow = false
        panel?.orderOut(nil)
    }

    /// Cmd-W routing hook, checked by `closeActivePaneOrWindow` alongside the
    /// other floating-panel controllers.
    func hideIfKeyWindow() -> Bool {
        guard isVisible, isKeyWindow else { return false }
        dismissByUser()
        return true
    }

    private func makePanel() -> FloatingSwiftUIPanelWindow {
        let panel = FloatingSwiftUIPanelWindow(
            contentRect: NSRect(origin: .zero, size: Self.fallbackSize),
            backing: .buffered,
            defer: false
        )
        panel.title = "Welcome to awesoMux"
        panel.setAccessibilityLabel("Welcome to awesoMux")
        panel.showsStandardWindowButtons = true
        // AboutPanelController leaves this at its `true` default, which fires
        // `onDismiss` whenever another window becomes key. Beat three opens
        // Settings, which would make it key — and dismiss the tour out from
        // under the user's own click. The tour must survive its own button,
        // so focus loss stays inert; only `dismissByUser()` may hide it.
        panel.dismissesOnResignKey = false
        panel.onDismiss = { [weak self] in self?.dismissByUser() }
        panel.onKeyStateChanged = { [weak self] isKey in
            self?.handleKeyStateChanged(isKey)
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

    /// The single handler both the real panel's `onKeyStateChanged` callback
    /// and the testing seam below route through. Flags only — this must never
    /// itself decide to dismiss (that's `dismissesOnResignKey = false`'s job
    /// above); collapsing the two would reintroduce the beat-three bug this
    /// controller exists to avoid.
    private func handleKeyStateChanged(_ isKey: Bool) {
        isKeyWindow = isKey
    }

    // MARK: - Test seams

    /// Flips `isVisible` without constructing a real `NSWindow` — swift-testing
    /// runs unbundled, and `FloatingSwiftUIPanelWindow` sizing/chrome assumes a
    /// live `NSScreen`/window server that isn't available there.
    func showForTesting() {
        isVisible = true
    }

    /// Routes through the same `handleKeyStateChanged` the real panel's
    /// `becomeKey()`/`resignKey()` overrides call, without constructing one.
    func handleKeyStateChangedForTesting(_ isKey: Bool) {
        handleKeyStateChanged(isKey)
    }
}
