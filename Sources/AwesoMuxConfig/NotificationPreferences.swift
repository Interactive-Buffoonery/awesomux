public struct NotificationPreferences: Equatable, Sendable {
    public enum InterruptionLevel: Equatable, Sendable {
        case active
        case timeSensitive
    }

    public var muted: Bool
    public var sound: Bool
    public var respectDoNotDisturb: Bool
    public var notifyOnNeedsAttention: Bool
    public var dockBounceOnNeedsAttention: Bool
    public var notifyOnTurnDone: Bool
    public var turnDoneAlertsWhenFocused: Bool
    public var showWorkspaceDetails: Bool

    public static let defaultValue = NotificationPreferences(config: .defaultValue)

    public init(
        muted: Bool,
        sound: Bool,
        respectDoNotDisturb: Bool,
        notifyOnNeedsAttention: Bool,
        dockBounceOnNeedsAttention: Bool = false,
        notifyOnTurnDone: Bool = false,
        turnDoneAlertsWhenFocused: Bool = false,
        showWorkspaceDetails: Bool = false
    ) {
        self.muted = muted
        self.sound = sound
        self.respectDoNotDisturb = respectDoNotDisturb
        self.notifyOnNeedsAttention = notifyOnNeedsAttention
        self.dockBounceOnNeedsAttention = dockBounceOnNeedsAttention
        self.notifyOnTurnDone = notifyOnTurnDone
        self.turnDoneAlertsWhenFocused = turnDoneAlertsWhenFocused
        self.showWorkspaceDetails = showWorkspaceDetails
    }

    public init(config: NotificationConfig) {
        self.init(
            muted: config.muted,
            sound: config.sound,
            respectDoNotDisturb: config.respectDoNotDisturb,
            notifyOnNeedsAttention: config.notifyOnNeedsAttention,
            dockBounceOnNeedsAttention: config.dockBounceOnNeedsAttention,
            notifyOnTurnDone: config.notifyOnTurnDone,
            turnDoneAlertsWhenFocused: config.turnDoneAlertsWhenFocused,
            showWorkspaceDetails: config.showWorkspaceDetails
        )
    }

    public func shouldDeliverNeedsAttention() -> Bool {
        !muted && notifyOnNeedsAttention
    }

    /// Dock bounce is an AppKit user-attention request, not a
    /// `UNUserNotificationCenter` delivery, so it cannot be delegated to
    /// system Focus filtering the way banners can. Keep it behind the DND
    /// preference instead of turning the Dock into a notification bypass.
    public func shouldBounceDockForNeedsAttention() -> Bool {
        shouldDeliverNeedsAttention()
            && dockBounceOnNeedsAttention
            && !respectDoNotDisturb
    }

    /// Whether a turn-done (agent finished its turn, waiting for you) banner may
    /// fire at all. Mute is the master kill; otherwise gated solely by the
    /// independent turn-done toggle.
    public func shouldDeliverTurnDone() -> Bool {
        !muted && notifyOnTurnDone
    }

    /// Whether a turn-done ping should also fire for the currently-focused
    /// workspace (sound-only). Requires both turn-done delivery and the nested
    /// focused sub-option.
    public func shouldDeliverTurnDoneWhenFocused() -> Bool {
        shouldDeliverTurnDone() && turnDoneAlertsWhenFocused
    }

    public func shouldPlaySoundForNeedsAttention() -> Bool {
        shouldDeliverNeedsAttention() && sound
    }

    /// Workspace details are a presentation preference that applies to any
    /// delivered banner, needs-attention or turn-done. Gating it on
    /// needs-attention delivery silently drops the user's choice on every
    /// turn-done banner (the turn-done-only user's whole disambiguation need).
    public func shouldShowWorkspaceDetails() -> Bool {
        !muted && showWorkspaceDetails
    }

    public var needsAttentionInterruptionLevel: InterruptionLevel {
        respectDoNotDisturb ? .active : .timeSensitive
    }
}
