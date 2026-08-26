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

    /// `.createdDefault` is the only `ConfigLoadSource` that means "nothing
    /// was on disk before this launch's bootstrap wrote it" — every other
    /// case (an existing/migrated/invalid/unreadable file) means the profile
    /// was used before. A filesystem probe for the config directory can't
    /// tell first launch from launch two: `AppSettingsStore.bootstrap()` runs
    /// on every launch and creates that directory itself before this can ever
    /// be checked, so it reads "exists" from the very first run onward. `nil`
    /// (bootstrap threw) is treated as evidence too — an unknown history is
    /// not license to re-onboard a possibly-returning user.
    static func hasPriorInstallEvidence(loadSource: ConfigLoadSource?) -> Bool {
        loadSource != .createdDefault
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

    /// The single condition `NotificationPrimePolicy` defers on, exposed as one
    /// derived value so the app can re-evaluate the prime on exactly one
    /// `.onChange`. Watching `isVisible` and `currentBeat` separately would fire
    /// on every page turn and on presentation too — six evaluations per tour to
    /// catch the one transition (reaching beat three, or dismissal) that ends
    /// the deferral.
    var isDeferringNotificationPrime: Bool { isVisible && !hasReachedNotificationBeat }

    /// Used only when measurement can't run — an unbundled/headless context
    /// where `NSHostingView` reports a degenerate fitting size.
    private static let fallbackSize = CGSize(width: 480, height: 420)

    /// Supplied by the app so beat three's button can open the agent settings
    /// section. A no-op default keeps the tour usable before that wiring exists.
    @ObservationIgnored var onOpenAgentSettings: () -> Void = {}

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Re-summoning resumes rather than restarting: `currentBeat` is
    /// deliberately left untouched here.
    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel

        panel.hostSwiftUIContent(makeRootView())

        if !isVisible {
            panel.setFixedContentSize(maximumBeatFittingSize())
            panel.center()
        }
        panel.presentAndFocus()
        isVisible = true
        // `presentAndFocus()` only makes the hosting view first responder; it
        // tells VoiceOver nothing, so a panel that appears over the empty state
        // is silent. The page's own initial accessibility focus then reads the
        // beat itself.
        AccessibilityNotification.Announcement(
            String(
                localized: "Welcome to awesoMux",
                comment: "Announced to VoiceOver when the welcome tour panel presents")
        ).post()
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

    @ViewBuilder
    private func makeRootView() -> some View {
        let root = FirstRunTourView(
            controller: self,
            shortcuts: resolvedShortcuts(),
            onOpenAgentSettings: { [weak self] in self?.onOpenAgentSettings() }
        )
        if let appSettingsStore {
            root.appearanceBridge(appSettingsStore)
        } else {
            root
        }
    }

    private func resolvedShortcuts() -> FirstRunTourShortcuts {
        FirstRunTourShortcuts(keyboard: appSettingsStore?.keyboard.value ?? .defaultValue)
    }

    /// Every beat is measured and the panel pinned to the tallest. Sizing to
    /// the current beat instead would resize the window under the user on each
    /// page turn, and sizing to beat one would clip the longer beats outright
    /// at large interface text sizes.
    private func maximumBeatFittingSize() -> CGSize {
        let shortcuts = resolvedShortcuts()
        var size = CGSize.zero
        for beat in 0..<Self.beatCount {
            let fitting = NSHostingView(
                rootView: measurementRoot(beat: beat, shortcuts: shortcuts)
            ).fittingSize
            size.width = max(size.width, fitting.width)
            size.height = max(size.height, fitting.height)
        }
        guard size.width > 0, size.height > 0 else { return Self.fallbackSize }
        return size
    }

    /// Measured through the same appearance bridge the live panel uses —
    /// without it the probe renders at scale 1.0 and the pinned height is short
    /// for anyone who moved the interface text-size slider.
    @ViewBuilder
    private func measurementRoot(beat: Int, shortcuts: FirstRunTourShortcuts) -> some View {
        let page = FirstRunTourPage(
            beat: beat,
            shortcuts: shortcuts,
            onBack: {},
            onNext: {},
            onDismiss: {},
            onOpenAgentSettings: {}
        )
        if let appSettingsStore {
            page.appearanceBridge(appSettingsStore)
        } else {
            page
        }
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
