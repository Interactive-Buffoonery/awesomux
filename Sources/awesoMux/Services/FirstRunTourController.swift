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
    /// The seeded flag is the *only* install-age input, and it is deliberately
    /// three-valued. Re-deriving age from `loadSource` here instead would ask a
    /// signal that is only meaningful on the launch that created the config,
    /// and get "existing" on every launch after — so a first launch interrupted
    /// before the tour was dismissed could never be resumed.
    ///
    /// `nil` means the seed has never run: this launch's bootstrap failed and
    /// no earlier launch classified the install. An unknown history is not
    /// licence to re-onboard a possibly-returning user; a later healthy launch
    /// seeds properly and this answers correctly then.
    static func shouldAutoPresent(
        seenFlag: Bool?,
        mode: EmptyWorkspaceMode
    ) -> Bool {
        guard seenFlag == false else { return false }
        return mode == .firstLaunch
    }

    /// `nil` when the flag has never been written — see `seedSeenFlagIfNeeded`.
    /// `bool(forKey:)` cannot express that: it reports a missing key as `false`,
    /// which is also the "seeded, genuinely new" answer.
    static func seenFlag(defaults: UserDefaults = .standard) -> Bool? {
        defaults.object(forKey: SettingsKey.hasSeenFirstRunTour) as? Bool
    }

    /// `.createdDefault` is the only `ConfigLoadSource` that means "nothing
    /// was on disk before this launch's bootstrap wrote it" — every other
    /// case (an existing/migrated/invalid/unreadable file) means the profile
    /// was used before. A filesystem probe for the config directory can't
    /// tell first launch from launch two: `AppSettingsStore.bootstrap()` runs
    /// on every launch and creates that directory itself before this can ever
    /// be checked, so it reads "exists" from the very first run onward.
    static func hasPriorInstallEvidence(loadSource: ConfigLoadSource) -> Bool {
        loadSource != .createdDefault
    }

    /// Written once per install, before the tour can ever evaluate. Without it
    /// an existing user upgrading into this build has the (false-by-default)
    /// flag and gets greeted as brand new.
    ///
    /// Two guards, both load-bearing:
    ///
    /// `loadSource` only separates new from existing on the launch that
    /// *created* the config; every launch after that reads `.existingFile`.
    /// Re-deriving a persisted decision from it on launch two would mean a
    /// first launch interrupted before the tour was dismissed (quit, crash, or
    /// simply never reaching the scene's `.onAppear`) permanently loses
    /// onboarding. Writing the classification exactly once — including the
    /// `false` a genuinely new install gets — makes launch two a no-op instead.
    ///
    /// A `nil` source means bootstrap threw and this launch knows nothing. That
    /// suppresses the tour for one launch (`shouldAutoPresent` above), but is
    /// never persisted: repairing the disk later would otherwise never restore
    /// onboarding.
    static func seedSeenFlagIfNeeded(
        defaults: UserDefaults = .standard,
        loadSource: ConfigLoadSource?
    ) {
        guard let loadSource else { return }
        guard seenFlag(defaults: defaults) == nil else { return }
        defaults.set(
            hasPriorInstallEvidence(loadSource: loadSource),
            forKey: SettingsKey.hasSeenFirstRunTour)
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
    @ObservationIgnored private var isAwaitingAgentSettingsClose = false
    @ObservationIgnored private let defaults: UserDefaults
    // Set by the app so this floating-panel root carries the appearance
    // bridge (accent, glow, UI font, text scale) — same contract as the
    // command palette / About / cheatsheet controllers.
    @ObservationIgnored var appSettingsStore: AppSettingsStore?

    private(set) var isVisible = false
    private(set) var currentBeat = 0
    /// Bumped on every presentation. The panel is reused across dismiss
    /// (`orderOut`, not `close`) and `hostSwiftUIContent` only swaps `rootView`,
    /// so SwiftUI keeps the page's identity and its `@State` — a one-shot
    /// "have I focused yet" flag therefore never fires again for a recall.
    /// Handing the page a value that changes per presentation is what lets it
    /// drive VoiceOver focus off presentation instead.
    private(set) var presentationToken = 0

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
    /// Supplied by the app so the optional closing-page action can complete
    /// onboarding before handing off to the separate Feature Atlas panel.
    @ObservationIgnored var onOpenFeatureAtlas: () -> Void = {}

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Re-summoning resumes rather than restarting: `currentBeat` is
    /// deliberately left untouched here and in `beginPresentation()`.
    func show() {
        let isFirstPresentation = !isVisible
        beginPresentation()

        let panel = panel ?? makePanel()
        self.panel = panel

        panel.hostSwiftUIContent(makeRootView())

        if isFirstPresentation {
            panel.setFixedContentSize(maximumBeatFittingSize())
            panel.center()
        }
        panel.presentAndFocus()
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

    /// Every part of `show()` that isn't the window. `showForTesting()` routes
    /// through this rather than duplicating the transition, so a regression
    /// that reset `currentBeat` on present would be caught by a test that can
    /// only run headless.
    private func beginPresentation() {
        presentationToken += 1
        isVisible = true
    }

    func advance() { currentBeat = min(currentBeat + 1, Self.beatCount - 1) }
    func retreat() { currentBeat = max(currentBeat - 1, 0) }

    /// Records that Settings belongs to the tour's beat-three handoff before
    /// opening it. A normal Settings visit never sets this marker, so closing
    /// that window keeps its existing behavior.
    func openAgentSettingsFromTour() {
        isAwaitingAgentSettingsClose = true
        onOpenAgentSettings()
    }

    /// Called by the singleton Settings scene when its content disappears.
    /// Consuming first makes duplicate lifecycle callbacks inert and lets
    /// `show()` return the existing panel to the front on its current beat.
    func resumeAfterAgentSettingsClose() {
        guard consumeAgentSettingsHandoff() else { return }
        show()
    }

    /// The atlas is an explicit branch from the closing beat, not a side effect
    /// of ordinary dismissal. The visibility guard also makes repeated button
    /// or accessibility activation idempotent.
    func discoverFeatures() {
        guard isVisible else { return }
        dismissByUser()
        onOpenFeatureAtlas()
    }

    /// Esc, Cmd-W, the close control, or finishing beat five. Only this path
    /// silences the tour — a tour that marked itself seen because the user
    /// clicked its own "Set up agents" button would end onboarding at beat
    /// three, permanently.
    func dismissByUser() {
        defaults.set(true, forKey: SettingsKey.hasSeenFirstRunTour)
        // Explicit dismissal wins even if Settings is still open from the
        // tour's handoff. Its later close must not resurrect onboarding.
        isAwaitingAgentSettingsClose = false
        // Reaching the closing beat *is* completing the tour, whichever control
        // ends it there. Leaving `currentBeat` on the last beat would make the
        // "?" button that beat five advertises reopen on a screen whose only
        // remaining control is Done. Dismissing mid-tour still resumes.
        if currentBeat == Self.beatCount - 1 { currentBeat = 0 }
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
        // The store itself, not a snapshot of its chords: resolving once here
        // would keep teaching the old key after beat three's own Settings
        // button is used to rebind one. `FirstRunTourView` resolves inside its
        // body, so Observation re-renders the live panel on a rebind.
        let root = FirstRunTourView(
            controller: self,
            appSettingsStore: appSettingsStore,
            presentationToken: presentationToken,
            onOpenAgentSettings: { [weak self] in self?.openAgentSettingsFromTour() }
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
            onOpenAgentSettings: {},
            onDiscoverFeatures: {}
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
        // Every other FloatingSwiftUIPanelWindow consumer dismisses on resign,
        // so its `.floating` level never has to coexist with another window.
        // The tour is the first that stays up after losing key — and floating
        // above normal windows means beat three's own "Set up agents…" opens
        // Settings *underneath* the tour, permanently unreachable. Ride normal
        // ordering while something else is key; float again when refocused so
        // the tour still sits above the main window during onboarding.
        //
        // Deferred because `onKeyStateChanged` is documented flags-only: it can
        // run inside `sendEvent` via the pointer re-key, and re-ordering a
        // window on that stack is exactly the reaction the contract excludes.
        // Reads `isKeyWindow` rather than the captured `isKey` so that if key
        // state flips twice before these land, the last state wins.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            panel?.level = isKeyWindow ? .floating : .normal
        }
    }

    // MARK: - Test seams

    /// Flips `isVisible` without constructing a real `NSWindow` — swift-testing
    /// runs unbundled, and `FloatingSwiftUIPanelWindow` sizing/chrome assumes a
    /// live `NSScreen`/window server that isn't available there.
    func showForTesting() {
        beginPresentation()
    }

    /// Routes through the same `handleKeyStateChanged` the real panel's
    /// `becomeKey()`/`resignKey()` overrides call, without constructing one.
    func handleKeyStateChangedForTesting(_ isKey: Bool) {
        handleKeyStateChanged(isKey)
    }

    /// Headless counterpart to `resumeAfterAgentSettingsClose()`. The real
    /// method must create/focus an NSWindow, which the Swift test runner cannot
    /// do reliably without an app bundle and window server.
    @discardableResult
    func resumeAfterAgentSettingsCloseForTesting() -> Bool {
        guard consumeAgentSettingsHandoff() else { return false }
        showForTesting()
        return true
    }

    private func consumeAgentSettingsHandoff() -> Bool {
        guard isAwaitingAgentSettingsClose else { return false }
        isAwaitingAgentSettingsClose = false
        return true
    }
}
