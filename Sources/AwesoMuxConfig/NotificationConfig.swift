public struct NotificationConfig: Codable, Equatable, Sendable {
    @TOMLDefault<DefaultNotificationsMuted> public var muted: Bool
    @TOMLDefault<DefaultNotificationsSound> public var sound: Bool
    @TOMLDefault<DefaultRespectDoNotDisturb> public var respectDoNotDisturb: Bool
    @TOMLDefault<DefaultNotifyOnNeedsAttention> public var notifyOnNeedsAttention: Bool
    @TOMLDefault<DefaultDockBounceOnNeedsAttention> public var dockBounceOnNeedsAttention: Bool
    /// Opt-in banner when an agent finishes its turn and is waiting for your
    /// next message (execution `.waiting`, no blocking prompt). Independent of
    /// `notifyOnNeedsAttention` so turn-end pings can be enabled without the
    /// louder permission/attention banners, or vice versa. Off by default.
    @TOMLDefault<DefaultNotifyOnTurnDone> public var notifyOnTurnDone: Bool
    /// Whether a turn-done ping also fires for the workspace you are currently
    /// looking at (delivered sound-only, no banner, to avoid a double-announce
    /// with the in-app chrome). Needs-attention keeps its list-only foreground
    /// contract regardless. Off by default.
    @TOMLDefault<DefaultTurnDoneAlertsWhenFocused> public var turnDoneAlertsWhenFocused: Bool
    @TOMLDefault<DefaultShowWorkspaceDetails> public var showWorkspaceDetails: Bool

    public static let defaultValue = NotificationConfig()

    public init(
        muted: Bool = DefaultNotificationsMuted.defaultValue,
        sound: Bool = DefaultNotificationsSound.defaultValue,
        respectDoNotDisturb: Bool = DefaultRespectDoNotDisturb.defaultValue,
        notifyOnNeedsAttention: Bool = DefaultNotifyOnNeedsAttention.defaultValue,
        dockBounceOnNeedsAttention: Bool = DefaultDockBounceOnNeedsAttention.defaultValue,
        notifyOnTurnDone: Bool = DefaultNotifyOnTurnDone.defaultValue,
        turnDoneAlertsWhenFocused: Bool = DefaultTurnDoneAlertsWhenFocused.defaultValue,
        showWorkspaceDetails: Bool = DefaultShowWorkspaceDetails.defaultValue
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

    enum CodingKeys: String, CodingKey, CaseIterable {
        case muted
        case sound
        case respectDoNotDisturb = "respect_do_not_disturb"
        case notifyOnNeedsAttention = "notify_on_needs_attention"
        case dockBounceOnNeedsAttention = "dock_bounce_on_needs_attention"
        case notifyOnTurnDone = "notify_on_turn_done"
        case turnDoneAlertsWhenFocused = "turn_done_alerts_when_focused"
        case showWorkspaceDetails = "show_workspace_details"
    }
}

public struct DefaultNotificationsMuted: DefaultProvider {
    public static let defaultValue = false
}

public struct DefaultNotificationsSound: DefaultProvider {
    public static let defaultValue = true
}

public struct DefaultRespectDoNotDisturb: DefaultProvider {
    public static let defaultValue = true
}

public struct DefaultNotifyOnNeedsAttention: DefaultProvider {
    public static let defaultValue = true
}

public struct DefaultDockBounceOnNeedsAttention: DefaultProvider {
    public static let defaultValue = false
}

public struct DefaultNotifyOnTurnDone: DefaultProvider {
    public static let defaultValue = false
}

public struct DefaultTurnDoneAlertsWhenFocused: DefaultProvider {
    public static let defaultValue = false
}

public struct DefaultShowWorkspaceDetails: DefaultProvider {
    public static let defaultValue = false
}
