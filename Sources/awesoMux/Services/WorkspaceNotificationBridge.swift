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

    private let center: UNUserNotificationCenter
    private let logger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "notifications"
    )
    private var preferencesProvider: @MainActor () -> NotificationPreferences
    private var authorizationStatus: UNAuthorizationStatus?

    init(
        center: UNUserNotificationCenter = .current(),
        preferencesProvider: @escaping @MainActor () -> NotificationPreferences = {
            .defaultValue
        }
    ) {
        self.center = center
        self.preferencesProvider = preferencesProvider
        registerNotificationCategories()
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

        refreshAuthorizationStatus { [weak self] status in
            guard status == .notDetermined else {
                return
            }

            self?.presentAuthorizationExplanation()
            self?.requestAuthorization()
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
            requestAuthorization { [weak self] isAuthorized in
                guard isAuthorized else {
                    return
                }

                self?.postAuthorizedWorkspaceNotification(event)
            }
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

    private func registerNotificationCategories() {
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
