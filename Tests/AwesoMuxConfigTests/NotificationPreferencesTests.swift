import Testing
@testable import AwesoMuxConfig

@Suite("NotificationPreferences")
struct NotificationPreferencesTests {
    @Test("muted notifications do not deliver or play sound")
    func mutedNotificationsDoNotDeliverOrPlaySound() {
        let preferences = NotificationPreferences(
            muted: true,
            sound: true,
            respectDoNotDisturb: true,
            notifyOnNeedsAttention: true
        )

        #expect(!preferences.shouldDeliverNeedsAttention())
        #expect(!preferences.shouldPlaySoundForNeedsAttention())
    }

    @Test("sound off still delivers attention notifications silently")
    func soundOffStillDeliversAttentionNotificationsSilently() {
        let preferences = NotificationPreferences(
            muted: false,
            sound: false,
            respectDoNotDisturb: true,
            notifyOnNeedsAttention: true
        )

        #expect(preferences.shouldDeliverNeedsAttention())
        #expect(!preferences.shouldPlaySoundForNeedsAttention())
    }

    @Test("sound on delivers attention notifications with sound")
    func soundOnDeliversAttentionNotificationsWithSound() {
        let preferences = NotificationPreferences(
            muted: false,
            sound: true,
            respectDoNotDisturb: true,
            notifyOnNeedsAttention: true
        )

        #expect(preferences.shouldDeliverNeedsAttention())
        #expect(preferences.shouldPlaySoundForNeedsAttention())
    }

    @Test("turn-done is independent of needs-attention and off by default")
    func turnDoneIsIndependentAndOffByDefault() {
        // Default config: needs-attention on, turn-done off.
        let defaults = NotificationPreferences(config: .defaultValue)
        #expect(defaults.shouldDeliverNeedsAttention())
        #expect(!defaults.shouldDeliverTurnDone())
        #expect(!defaults.shouldDeliverTurnDoneWhenFocused())

        // Turn-done on, needs-attention off: fully independent toggles.
        let turnDoneOnly = NotificationPreferences(
            muted: false,
            sound: true,
            respectDoNotDisturb: true,
            notifyOnNeedsAttention: false,
            notifyOnTurnDone: true
        )
        #expect(!turnDoneOnly.shouldDeliverNeedsAttention())
        #expect(turnDoneOnly.shouldDeliverTurnDone())
    }

    @Test("mute is the master kill for turn-done")
    func muteKillsTurnDone() {
        let muted = NotificationPreferences(
            muted: true,
            sound: true,
            respectDoNotDisturb: true,
            notifyOnNeedsAttention: true,
            notifyOnTurnDone: true,
            turnDoneAlertsWhenFocused: true
        )
        #expect(!muted.shouldDeliverTurnDone())
        #expect(!muted.shouldDeliverTurnDoneWhenFocused())
    }

    @Test("focused turn-done requires both the toggle and the sub-option")
    func focusedTurnDoneRequiresBoth() {
        let base = NotificationPreferences(
            muted: false,
            sound: true,
            respectDoNotDisturb: true,
            notifyOnNeedsAttention: false,
            notifyOnTurnDone: true,
            turnDoneAlertsWhenFocused: false
        )
        #expect(base.shouldDeliverTurnDone())
        #expect(!base.shouldDeliverTurnDoneWhenFocused())

        let focused = NotificationPreferences(
            muted: false,
            sound: true,
            respectDoNotDisturb: true,
            notifyOnNeedsAttention: false,
            notifyOnTurnDone: true,
            turnDoneAlertsWhenFocused: true
        )
        #expect(focused.shouldDeliverTurnDoneWhenFocused())
    }

    @Test("needs-attention toggle gates delivery")
    func needsAttentionToggleGatesDelivery() {
        let preferences = NotificationPreferences(
            muted: false,
            sound: true,
            respectDoNotDisturb: true,
            notifyOnNeedsAttention: false
        )

        #expect(!preferences.shouldDeliverNeedsAttention())
        #expect(!preferences.shouldPlaySoundForNeedsAttention())
    }

    @Test("dock bounce requires attention delivery opt-in and DND bypass")
    func dockBounceRequiresAttentionDeliveryOptInAndDNDBypass() {
        let enabled = NotificationPreferences(
            muted: false,
            sound: true,
            respectDoNotDisturb: false,
            notifyOnNeedsAttention: true,
            dockBounceOnNeedsAttention: true
        )
        #expect(enabled.shouldBounceDockForNeedsAttention())

        let respectsDND = NotificationPreferences(
            muted: false,
            sound: true,
            respectDoNotDisturb: true,
            notifyOnNeedsAttention: true,
            dockBounceOnNeedsAttention: true
        )
        #expect(!respectsDND.shouldBounceDockForNeedsAttention())

        let attentionOff = NotificationPreferences(
            muted: false,
            sound: true,
            respectDoNotDisturb: false,
            notifyOnNeedsAttention: false,
            dockBounceOnNeedsAttention: true
        )
        #expect(!attentionOff.shouldBounceDockForNeedsAttention())

        let bounceOff = NotificationPreferences(
            muted: false,
            sound: true,
            respectDoNotDisturb: false,
            notifyOnNeedsAttention: true,
            dockBounceOnNeedsAttention: false
        )
        #expect(!bounceOff.shouldBounceDockForNeedsAttention())
    }

    @Test("workspace details are opt-in, gated only by mute, not by channel")
    func workspaceDetailsAreOptInGatedOnlyByMute() {
        let enabled = NotificationPreferences(
            muted: false,
            sound: true,
            respectDoNotDisturb: true,
            notifyOnNeedsAttention: true,
            showWorkspaceDetails: true
        )
        let muted = NotificationPreferences(
            muted: true,
            sound: true,
            respectDoNotDisturb: true,
            notifyOnNeedsAttention: true,
            showWorkspaceDetails: true
        )
        let optOut = NotificationPreferences(
            muted: false,
            sound: true,
            respectDoNotDisturb: true,
            notifyOnNeedsAttention: true,
            showWorkspaceDetails: false
        )
        // Turn-done-only user: details is a presentation preference and must
        // still apply even though needs-attention delivery is off.
        let turnDoneOnly = NotificationPreferences(
            muted: false,
            sound: true,
            respectDoNotDisturb: true,
            notifyOnNeedsAttention: false,
            notifyOnTurnDone: true,
            showWorkspaceDetails: true
        )

        #expect(enabled.shouldShowWorkspaceDetails())
        #expect(!muted.shouldShowWorkspaceDetails())
        #expect(!optOut.shouldShowWorkspaceDetails())
        #expect(turnDoneOnly.shouldShowWorkspaceDetails())
    }

    @Test(
        "DND preference maps to interruption level",
        arguments: [
            (respectDoNotDisturb: true, level: NotificationPreferences.InterruptionLevel.active),
            (respectDoNotDisturb: false, level: NotificationPreferences.InterruptionLevel.timeSensitive)
        ]
    )
    func dndPreferenceMapsToInterruptionLevel(
        respectDoNotDisturb: Bool,
        level: NotificationPreferences.InterruptionLevel
    ) {
        let preferences = NotificationPreferences(
            muted: false,
            sound: true,
            respectDoNotDisturb: respectDoNotDisturb,
            notifyOnNeedsAttention: true
        )

        #expect(preferences.needsAttentionInterruptionLevel == level)
    }

    @Test("config initializer copies notification config")
    func configInitializerCopiesNotificationConfig() {
        let config = NotificationConfig(
            muted: true,
            sound: false,
            respectDoNotDisturb: false,
            notifyOnNeedsAttention: false,
            dockBounceOnNeedsAttention: true,
            notifyOnTurnDone: true,
            turnDoneAlertsWhenFocused: true,
            showWorkspaceDetails: true
        )

        #expect(NotificationPreferences(config: config) == NotificationPreferences(
            muted: true,
            sound: false,
            respectDoNotDisturb: false,
            notifyOnNeedsAttention: false,
            dockBounceOnNeedsAttention: true,
            notifyOnTurnDone: true,
            turnDoneAlertsWhenFocused: true,
            showWorkspaceDetails: true
        ))
    }
}
