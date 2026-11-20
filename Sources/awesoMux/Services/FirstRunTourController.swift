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

/// Floating-panel presenter for the setup wizard, mirroring
/// `AboutPanelController`. The panel is kept alive across dismiss (orderOut,
/// not close) so a re-summon within the session resumes rather than restarts.
@MainActor
@Observable
final class FirstRunTourController {
    @ObservationIgnored private var panel: FloatingSwiftUIPanelWindow?
    @ObservationIgnored private var isKeyWindow = false
    @ObservationIgnored private let defaults: UserDefaults
    // Set by the app so this floating-panel root carries the appearance
    // bridge (accent, glow, UI font, text scale) — same contract as the
    // command palette / About / cheatsheet controllers.
    @ObservationIgnored var appSettingsStore: AppSettingsStore?
    /// Supplied by the app: the last step's button runs New Workspace.
    @ObservationIgnored var onCreateFirstWorkspace: () -> Void = {}
    /// Supplied by the app: shows the macOS notification prompt.
    @ObservationIgnored var requestNotificationAuthorization: (@escaping @MainActor (Bool) -> Void) -> Void = {
        $0(false)
    }

    let notificationAuthorization: NotificationAuthorizationModel
    private(set) var agents: SetupWizardAgentsModel?

    private(set) var isVisible = false
    let steps: [SetupWizardStep]
    let hasGhosttyConfig: Bool
    private(set) var currentStepIndex = 0
    /// Bumped on every presentation. The panel is reused across dismiss
    /// (`orderOut`, not `close`) and `hostSwiftUIContent` only swaps `rootView`,
    /// so SwiftUI keeps the page's identity and its `@State` — a one-shot
    /// "have I focused yet" flag therefore never fires again for a recall.
    /// Handing the page a value that changes per presentation is what lets it
    /// drive VoiceOver focus off presentation instead.
    private(set) var presentationToken = 0

    var currentStep: SetupWizardStep { steps[min(currentStepIndex, steps.count - 1)] }

    /// Used only when measurement can't run — an unbundled/headless context
    /// where `NSHostingView` reports a degenerate fitting size.
    private static let fallbackSize = CGSize(width: 480, height: 420)

    /// `hasGhosttyConfig` must be read before `GhosttyRuntime` starts:
    /// libghostty writes a template `config.ghostty` when no config exists,
    /// which would make every clean install look configured.
    init(defaults: UserDefaults = .standard, hasGhosttyConfig: Bool = true) {
        self.defaults = defaults
        self.hasGhosttyConfig = hasGhosttyConfig
        steps = SetupWizardStep.steps(hasGhosttyConfig: hasGhosttyConfig)
        notificationAuthorization = NotificationAuthorizationModel()
    }

    /// Re-summoning resumes rather than restarting: `currentStepIndex` is
    /// deliberately left untouched here.
    func show() {
        guard let store = appSettingsStore else { return }
        let isFirstPresentation = !isVisible

        let panel: FloatingSwiftUIPanelWindow
        if let existing = self.panel {
            panel = existing
        } else {
            agents = SetupWizardAgentsModel(store: store)
            panel = makePanel()
            self.panel = panel
        }

        presentationToken += 1
        isVisible = true
        panel.hostSwiftUIContent(SetupWizardView(controller: self, store: store).appearanceBridge(store))

        if isFirstPresentation {
            panel.setFixedContentSize(maximumStepFittingSize(store: store))
            panel.center()
        }
        panel.presentAndFocus()
        // `presentAndFocus()` only makes the hosting view first responder; it
        // tells VoiceOver nothing, so a panel that appears over the empty state
        // is silent. The page's own initial accessibility focus then reads the
        // step itself.
        AccessibilityNotification.Announcement(
            String(
                localized: "Welcome to awesoMux",
                comment: "Announced to VoiceOver when the welcome tour panel presents")
        ).post()
    }

    func advance() {
        // Without a Ghostty config the appearance step shows Catppuccin as
        // already chosen; continuing past it confirms that choice.
        if currentStep == .appearance, !hasGhosttyConfig,
            let store = appSettingsStore, store.appearance.value.terminalBackgroundMode == .ghostty
        {
            store.appearance.update { $0.terminalBackgroundMode = .catppuccinTheme }
        }
        currentStepIndex = min(currentStepIndex + 1, steps.count - 1)
    }

    func retreat() { currentStepIndex = max(currentStepIndex - 1, 0) }

    func requestNotifications() {
        requestNotificationAuthorization { [weak self] _ in
            self?.notificationAuthorization.refresh()
        }
    }

    /// Esc, Cmd-W, the close control, or Skip. Dismissing mid-wizard resumes
    /// on the same step next time; dismissing on the last step starts over,
    /// so the "?" button never reopens on a screen whose only job is done.
    func dismissByUser() {
        hide(resettingProgress: currentStepIndex == steps.count - 1)
    }

    func createFirstWorkspace() {
        hide(resettingProgress: true)
        onCreateFirstWorkspace()
    }

    private func hide(resettingProgress: Bool) {
        defaults.set(true, forKey: SettingsKey.hasSeenFirstRunTour)
        if resettingProgress { currentStepIndex = 0 }
        isVisible = false
        isKeyWindow = false
        agents?.cancelPendingWork()
        panel?.orderOut(nil)
    }

    /// Cmd-W routing hook, checked by `closeActivePaneOrWindow` alongside the
    /// other floating-panel controllers.
    func hideIfKeyWindow() -> Bool {
        guard isVisible, isKeyWindow else { return false }
        dismissByUser()
        return true
    }

    /// Every step is measured and the panel pinned to the tallest, capped to
    /// the screen; the page scrolls past that. Sizing per step would resize
    /// the window under the user on each page turn. Measured through the same
    /// appearance bridge the live panel uses, so interface text size counts.
    private func maximumStepFittingSize(store: AppSettingsStore) -> CGSize {
        var size = CGSize.zero
        for step in steps {
            let page = SetupWizardPage(controller: self, store: store, step: step, isMeasuring: true)
            let fitting = NSHostingView(rootView: page.appearanceBridge(store)).fittingSize
            size.width = max(size.width, fitting.width)
            size.height = max(size.height, fitting.height)
        }
        guard size.width > 0, size.height > 0 else { return Self.fallbackSize }
        if let visibleHeight = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height {
            size.height = min(size.height, visibleHeight - 80)
        }
        return size
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
        // `onDismiss` whenever another window becomes key. The macOS
        // notification prompt the agents step raises takes key, and so does a
        // click into the main window to try a setting; neither should end the
        // wizard. Focus loss stays inert; only `dismissByUser()` may hide it.
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

    /// Flags only — this must never itself decide to dismiss (that's
    /// `dismissesOnResignKey = false`'s job above).
    private func handleKeyStateChanged(_ isKey: Bool) {
        isKeyWindow = isKey
        // Every other FloatingSwiftUIPanelWindow consumer dismisses on resign,
        // so its `.floating` level never has to coexist with another window.
        // The wizard stays up after losing key, so it rides normal ordering
        // while something else is key (Settings opened from the menu would
        // otherwise sit underneath it) and floats again when refocused.
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
}
