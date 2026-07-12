import AwesoMuxConfig
import Testing
import UserNotifications
@testable import awesoMux

/// Pins the INT-598 gap-3 product contract: while awesoMux is the active app,
/// a needs-attention notification — including one for a non-selected
/// workspace — lands in Notification Center's list only (no banner, no
/// sound); the in-app chrome carries the signal. Inactive app gets the full
/// banner (+ sound when enabled). Keep in sync with
/// `WorkspaceNotificationBridge.foregroundPresentationOptions` and the
/// notification-policy section of `docs/architecture.md`.
@Suite("Workspace notification foreground presentation contract")
struct WorkspaceNotificationForegroundPolicyTests {
    @Test("active app delivers list-only, even for other-workspace attention")
    func activeAppIsListOnly() {
        let options = WorkspaceNotificationBridge.foregroundPresentationOptions(
            isAppActive: true,
            preferences: .defaultValue
        )

        #expect(options == [.list])
        #expect(!options.contains(.banner))
        #expect(!options.contains(.sound))
    }

    @Test("inactive app delivers banner, list, and sound")
    func inactiveAppInterrupts() {
        let options = WorkspaceNotificationBridge.foregroundPresentationOptions(
            isAppActive: false,
            preferences: .defaultValue
        )

        #expect(options.contains(.banner))
        #expect(options.contains(.list))
        #expect(options.contains(.sound))
    }

    @Test("inactive app with sound disabled stays silent but still banners")
    func inactiveAppSoundOff() {
        let preferences = NotificationPreferences(
            muted: false,
            sound: false,
            respectDoNotDisturb: true,
            notifyOnNeedsAttention: true
        )

        let options = WorkspaceNotificationBridge.foregroundPresentationOptions(
            isAppActive: false,
            preferences: preferences
        )

        #expect(options.contains(.banner))
        #expect(!options.contains(.sound))
    }

    @Test("global mute suppresses all presentation", arguments: [true, false])
    func globalMuteSuppresses(isAppActive: Bool) {
        let preferences = NotificationPreferences(
            muted: true,
            sound: true,
            respectDoNotDisturb: true,
            notifyOnNeedsAttention: true
        )

        let options = WorkspaceNotificationBridge.foregroundPresentationOptions(
            isAppActive: isAppActive,
            preferences: preferences
        )

        #expect(options.isEmpty)
    }

    @Test("focused turn-done is sound-only when the sub-option is on")
    func focusedTurnDoneSoundOnly() {
        let preferences = NotificationPreferences(
            muted: false,
            sound: true,
            respectDoNotDisturb: true,
            notifyOnNeedsAttention: false,
            notifyOnTurnDone: true,
            turnDoneAlertsWhenFocused: true
        )

        let options = WorkspaceNotificationBridge.foregroundPresentationOptions(
            isAppActive: true,
            isTurnDone: true,
            preferences: preferences
        )

        #expect(options == [.sound])
        #expect(!options.contains(.banner))
        #expect(!options.contains(.list))
    }

    @Test("focused turn-done is silent without the sub-option")
    func focusedTurnDoneSilentWithoutSubOption() {
        let preferences = NotificationPreferences(
            muted: false,
            sound: true,
            respectDoNotDisturb: true,
            notifyOnNeedsAttention: false,
            notifyOnTurnDone: true,
            turnDoneAlertsWhenFocused: false
        )

        let options = WorkspaceNotificationBridge.foregroundPresentationOptions(
            isAppActive: true,
            isTurnDone: true,
            preferences: preferences
        )

        #expect(options.isEmpty)
    }

    @Test("inactive turn-done banners like any other notification")
    func inactiveTurnDoneBanners() {
        let preferences = NotificationPreferences(
            muted: false,
            sound: true,
            respectDoNotDisturb: true,
            notifyOnNeedsAttention: false,
            notifyOnTurnDone: true
        )

        let options = WorkspaceNotificationBridge.foregroundPresentationOptions(
            isAppActive: false,
            isTurnDone: true,
            preferences: preferences
        )

        #expect(options.contains(.banner))
        #expect(options.contains(.list))
        #expect(options.contains(.sound))
    }

    @Test("turn-done presentation is empty when its toggle is off")
    func turnDoneEmptyWhenToggleOff() {
        let options = WorkspaceNotificationBridge.foregroundPresentationOptions(
            isAppActive: false,
            isTurnDone: true,
            preferences: .defaultValue
        )

        #expect(options.isEmpty)
    }
}

@Suite("Notification authorization remediation (INT-598)")
struct NotificationAuthorizationModelTests {
    @Test("system statuses collapse onto the product display states")
    func displayStatusMapping() {
        #expect(NotificationAuthorizationModel.displayStatus(for: .authorized) == .authorized)
        #expect(NotificationAuthorizationModel.displayStatus(for: .provisional) == .authorized)
        #expect(NotificationAuthorizationModel.displayStatus(for: .denied) == .denied)
        #expect(NotificationAuthorizationModel.displayStatus(for: .notDetermined) == .notDetermined)
    }

    @Test("System Settings deep link targets this app's notifications pane")
    func systemSettingsURL() {
        let url = NotificationAuthorizationModel.systemNotificationSettingsURL(
            bundleIdentifier: "com.interactivebuffoonery.awesomux"
        )

        #expect(
            url?.absoluteString
                == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.interactivebuffoonery.awesomux"
        )
    }

    @Test("deep link falls back to the pane root without a bundle identifier")
    func systemSettingsURLFallback() {
        let url = NotificationAuthorizationModel.systemNotificationSettingsURL(
            bundleIdentifier: nil
        )

        #expect(
            url?.absoluteString
                == "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        )
    }

    @MainActor
    @Test("refresh publishes the provider's status")
    func refreshPublishesStatus() {
        var capturedCompletion: (@MainActor (UNAuthorizationStatus) -> Void)?
        let model = NotificationAuthorizationModel(statusProvider: { completion in
            capturedCompletion = completion
        })

        #expect(model.status == .unknown)
        model.refresh()
        capturedCompletion?(.denied)
        #expect(model.status == .denied)

        model.refresh()
        capturedCompletion?(.authorized)
        #expect(model.status == .authorized)
    }
}
