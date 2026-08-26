import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import Foundation
import os
@preconcurrency import UserNotifications

@MainActor
final class WorkspaceNotificationBridge {
    private enum Category {
        static let workspaceNeedsAttention = "workspace-needs-attention"
    }

    private let logger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "notifications"
    )
    private var preferencesProvider: @MainActor () -> NotificationPreferences
    private var authorizationStatus: UNAuthorizationStatus?

    /// Set for the whole explanation-plus-request round trip. The status fetch
    /// is async, so without this a burst of group mutations can each start a
    /// round trip and stack multiple explanation modals.
    private(set) var isAuthorizationRequestInFlight = false

    /// Events that arrived while authorization was still undetermined. They
    /// wait for the one round trip below instead of each starting their own —
    /// `AppDelegate.evaluateAndPostNotifications()` posts a whole batch in a
    /// synchronous loop, and `authorizationStatus` only updates on the first
    /// request's async completion.
    private var pendingAuthorizationEvents: [WorkspaceNotificationEvent] = []

    /// A burst is only worth replaying so far; beyond this the oldest are the
    /// least useful. ponytail: fixed cap, revisit only if a real batch ever
    /// exceeds it.
    private static let pendingAuthorizationEventLimit = 8

    /// `UNUserNotificationCenter.current()` reads `Bundle.main` and crashes
    /// when the calling process isn't a real app bundle — true of the
    /// unbundled `swift test` runner. `lazy` defers that call past
    /// construction, so a bridge can still be built for tests that never
    /// touch a real notification round trip (there is no other way to get an
    /// instance: its designated init is unavailable and it can't be
    /// subclassed).
    private lazy var center: UNUserNotificationCenter = {
        let center = UNUserNotificationCenter.current()
        registerNotificationCategories(on: center)
        return center
    }()

    /// The cached status short-circuits the `getNotificationSettings` round
    /// trip, which is only safe while the answer cannot have changed behind our
    /// back. It can: Settings → Notifications deep-links the user into System
    /// Settings precisely so a `.denied` decision can be reversed (INT-598), and
    /// `NotificationAuthorizationModel` re-queries there without writing back
    /// here. Returning to awesoMux is the one bounded moment that can have
    /// happened, so the cache is dropped there rather than on every agent tick.
    @ObservationIgnored private var didBecomeActiveObserver: NSObjectProtocol?

    init(
        preferencesProvider: @escaping @MainActor () -> NotificationPreferences = {
            .defaultValue
        }
    ) {
        self.preferencesProvider = preferencesProvider
        // `object: nil` deliberately: resolving `NSApp` here would boot AppKit
        // in the unbundled test runner just to register an observer.
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.authorizationStatus = nil }
        }
    }

    isolated deinit {
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
    }

    func configurePreferencesProvider(
        _ provider: @escaping @MainActor () -> NotificationPreferences
    ) {
        preferencesProvider = provider
    }

    func requestAuthorizationWithExplanationIfNeeded() {
        // Either deliverable channel warrants priming the permission ask. A
        // turn-done-only user (needs-attention off, turn-done on) would
        // otherwise never see the explanation, then get a cold system dialog
        // mid-session on their first turn-end — spent once, then gone.
        let preferences = preferencesProvider()
        guard preferences.shouldDeliverNeedsAttention()
            || preferences.shouldDeliverTurnDone() else {
            return
        }

        guard !isAuthorizationRequestInFlight else {
            return
        }

        // Priming is driven off session-store mutations, which tick on ordinary
        // agent state changes. Without this, a settled answer is re-fetched
        // from notifyd forever; `refreshAuthorizationStatus` is only worth an
        // XPC round trip while the answer can still change.
        if let authorizationStatus, authorizationStatus != .notDetermined {
            handlePrimeStatus(authorizationStatus)
            return
        }

        isAuthorizationRequestInFlight = true

        refreshAuthorizationStatus { [weak self] status in
            self?.handlePrimeStatus(status)
        }
    }

    /// Split out of `requestAuthorizationWithExplanationIfNeeded`'s status
    /// completion (not `private`) so both flag-clearing exits are callable
    /// directly with a plain `UNAuthorizationStatus` — unit-testable without
    /// constructing a `UNUserNotificationCenter`, same reasoning as the
    /// `nonisolated static foregroundPresentationOptions` above. Only the
    /// `!= .notDetermined` branch is safe to drive from a test: the
    /// `.notDetermined` branch calls a real, blocking `NSAlert.runModal()`.
    func handlePrimeStatus(_ status: UNAuthorizationStatus) {
        guard status == .notDetermined else {
            isAuthorizationRequestInFlight = false
            let isAuthorized: Bool =
                switch status {
                case .authorized, .provisional, .ephemeral: true
                default: false
                }
            flushPendingAuthorizationEvents(isAuthorized: isAuthorized)
            return
        }

        presentAuthorizationExplanation()
        requestAuthorization { [weak self] granted in
            self?.handlePrimeRequestResult(granted: granted)
        }
    }

    /// Split out of the same round trip's request completion, for the same
    /// reason — lets a test drive the "the request finished" exit directly
    /// with a plain `Bool`, without a real `UNUserNotificationCenter`.
    func handlePrimeRequestResult(granted: Bool) {
        isAuthorizationRequestInFlight = false
        flushPendingAuthorizationEvents(isAuthorized: granted)
    }

    private func flushPendingAuthorizationEvents(isAuthorized: Bool) {
        let events = pendingAuthorizationEvents
        pendingAuthorizationEvents.removeAll()
        guard isAuthorized else { return }
        for event in events {
            postAuthorizedWorkspaceNotification(event)
        }
    }

    func postWorkspaceNotification(_ event: WorkspaceNotificationEvent) {
        guard Self.shouldDeliver(event, preferences: preferencesProvider()) else {
            return
        }

        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            postAuthorizedWorkspaceNotification(event)
        case .notDetermined:
            // Never requests here. This path used to call
            // `center.requestAuthorization` directly, which showed the bare
            // system dialog with no explanation — and, because the caller posts
            // a batch synchronously while `authorizationStatus` updates only on
            // the first completion, once per eligible event. The event waits for
            // the single guarded round trip instead.
            pendingAuthorizationEvents.append(event)
            if pendingAuthorizationEvents.count > Self.pendingAuthorizationEventLimit {
                pendingAuthorizationEvents.removeFirst()
            }
            requestAuthorizationWithExplanationIfNeeded()
        case .denied:
            // Deliberately quiet at post time: macOS shows the permission
            // dialog at most once, so there is nothing useful to do here.
            // The user-facing remediation lives in Settings → Notifications
            // (permission status + System Settings deep link, INT-598).
            logger.info("skipping workspace notification: authorization denied")
        case nil:
            refreshAuthorizationStatus { [weak self] _ in
                self?.postWorkspaceNotification(event)
            }
        @unknown default:
            break
        }
    }

    func foregroundPresentationOptions(
        isAppActive: Bool,
        isTurnDone: Bool = false
    ) -> UNNotificationPresentationOptions {
        Self.foregroundPresentationOptions(
            isAppActive: isAppActive,
            isTurnDone: isTurnDone,
            preferences: preferencesProvider()
        )
    }

    /// Foreground presentation contract (INT-598 gap 3, deliberate product
    /// decision — keep code, tests, and `docs/architecture.md` in sync):
    ///
    /// While awesoMux is the active app, a needs-attention notification —
    /// including one for a workspace other than the selected one — is
    /// delivered to Notification Center's list ONLY. No banner, no sound:
    /// the in-app chrome (sidebar dot, tab indicator, dock badge, VoiceOver
    /// announcement) already carries the signal, and a banner on top would
    /// double-announce for VoiceOver users. When the app is inactive the
    /// banner (and sound, when enabled) interrupts as usual.
    ///
    /// Turn-done pings follow their own foreground contract: when the app is
    /// active they present sound-only (no banner, no list) IF the focused
    /// sub-option is on, so a focused turn-end is an audible cue without a
    /// redundant banner; when inactive they interrupt like any other banner.
    /// A turn-done event only reaches this active-and-focused path when the
    /// tracker already allowed it (the focused sub-option gates emission too).
    ///
    /// Static, nonisolated, and pure so the contract is unit-testable without
    /// constructing a `UNUserNotificationCenter` (which requires a real app
    /// bundle).
    nonisolated static func foregroundPresentationOptions(
        isAppActive: Bool,
        isTurnDone: Bool = false,
        preferences: NotificationPreferences
    ) -> UNNotificationPresentationOptions {
        if isTurnDone {
            guard preferences.shouldDeliverTurnDone() else {
                return []
            }
            if isAppActive {
                return preferences.shouldDeliverTurnDoneWhenFocused() && preferences.sound
                    ? [.sound]
                    : []
            }
            var options: UNNotificationPresentationOptions = [.banner, .list]
            if preferences.sound {
                options.insert(.sound)
            }
            return options
        }

        guard preferences.shouldDeliverNeedsAttention() else {
            return []
        }

        if isAppActive {
            return [.list]
        }

        var options: UNNotificationPresentationOptions = [.banner, .list]
        if preferences.shouldPlaySoundForNeedsAttention() {
            options.insert(.sound)
        }
        return options
    }

    /// Takes the resolved center as a parameter, not `self.center`, because
    /// this runs from inside `center`'s own lazy initializer — reading
    /// `self.center` there would re-enter it.
    private func registerNotificationCategories(on center: UNUserNotificationCenter) {
        let openAction = UNNotificationAction(
            identifier: "open-awesomux",
            title: "Open awesoMux",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Category.workspaceNeedsAttention,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    private func presentAuthorizationExplanation() {
        explanationPresentationCountForTesting += 1

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Allow awesoMux notifications?"
        alert.informativeText = "awesoMux can notify you when a background workspace or agent needs attention."
        alert.addButton(withTitle: "Continue")
        alert.runModal()
    }

    private func refreshAuthorizationStatus(
        completion: @escaping @MainActor (UNAuthorizationStatus) -> Void
    ) {
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                self?.authorizationStatus = settings.authorizationStatus
                completion(settings.authorizationStatus)
            }
        }
    }

    private func requestAuthorization(
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        center.requestAuthorization(options: [.alert, .badge, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                if let error {
                    self?.logger.error("failed to request notification authorization: \(error.localizedDescription, privacy: .public)")
                    self?.authorizationStatus = .denied
                    completion?(false)
                    return
                }

                self?.authorizationStatus = granted ? .authorized : .denied
                self?.logger.info("notification authorization granted: \(granted, privacy: .public)")
                completion?(granted)
            }
        }
    }

    /// Whether an event of this kind may be delivered at all, given the user's
    /// preferences. Needs-attention and turn-done ride independent toggles.
    nonisolated static func shouldDeliver(
        _ event: WorkspaceNotificationEvent,
        preferences: NotificationPreferences
    ) -> Bool {
        switch event.kind {
        case .needsAttention:
            preferences.shouldDeliverNeedsAttention()
        case .turnDone:
            preferences.shouldDeliverTurnDone()
        }
    }

    private func postAuthorizedWorkspaceNotification(_ event: WorkspaceNotificationEvent) {
        let preferences = preferencesProvider()
        guard Self.shouldDeliver(event, preferences: preferences) else {
            return
        }

        let content = UNMutableNotificationContent()
        switch event.kind {
        case .needsAttention:
            content.title = String(
                localized: "\(event.agentKind.shortName) needs attention",
                comment: "Notification title shown when a background agent workspace transitions to needs-attention. Argument is the agent product name (e.g. Claude, Codex, Shell)."
            )
            content.body = String(
                localized: "A background workspace is waiting for you.",
                comment: "Notification body for workspace-needs-attention banners."
            )
        case .turnDone:
            content.title = String(
                localized: "\(event.agentKind.shortName) finished your turn",
                comment: "Notification title shown when a background agent finishes its turn and is waiting for the user's next message. Argument is the agent product name (e.g. Claude, Codex)."
            )
            content.body = String(
                localized: "It's your turn — \(event.agentKind.shortName) is waiting for your next message.",
                comment: "Notification body for turn-done banners. Argument is the agent product name."
            )
        }
        content.subtitle = notificationSubtitle(for: event, preferences: preferences)
        content.categoryIdentifier = Category.workspaceNeedsAttention
        content.interruptionLevel = preferences.needsAttentionInterruptionLevel.userNotificationLevel
        let playsSound: Bool = switch event.kind {
        case .needsAttention: preferences.shouldPlaySoundForNeedsAttention()
        case .turnDone: preferences.shouldDeliverTurnDone() && preferences.sound
        }
        content.sound = playsSound ? .default : nil
        content.threadIdentifier = event.sessionID.uuidString
        var userInfo: [String: String] = [
            WorkspaceNotificationUserInfoKey.sessionID: event.sessionID.uuidString
        ]
        if event.kind == .turnDone {
            userInfo[WorkspaceNotificationUserInfoKey.kind] =
                WorkspaceNotificationUserInfoKey.turnDoneKindValue
        }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        center.add(request) { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.logger.error("failed to post workspace notification: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func notificationSubtitle(
        for event: WorkspaceNotificationEvent,
        preferences: NotificationPreferences
    ) -> String {
        event.notificationSubtitle(
            showWorkspaceDetails: preferences.shouldShowWorkspaceDetails()
        )
    }

    // MARK: - Test seams

    /// Forces the in-flight state without a real round trip, so coalescing
    /// can be tested without driving `UNUserNotificationCenter` (which
    /// requires a real app bundle and crashes an unbundled test process).
    func beginAuthorizationRequestForTesting() {
        isAuthorizationRequestInFlight = true
    }

    /// Seeds the cached status so `postWorkspaceNotification`'s routing can be
    /// driven without a real `UNUserNotificationCenter` round trip.
    func setAuthorizationStatusForTesting(_ status: UNAuthorizationStatus?) {
        authorizationStatus = status
    }

    var pendingAuthorizationEventCountForTesting: Int { pendingAuthorizationEvents.count }

    var authorizationStatusForTesting: UNAuthorizationStatus? { authorizationStatus }

    private(set) var explanationPresentationCountForTesting = 0
}

private extension NotificationPreferences.InterruptionLevel {
    var userNotificationLevel: UNNotificationInterruptionLevel {
        switch self {
        case .active:
            .active
        case .timeSensitive:
            .timeSensitive
        }
    }
}
