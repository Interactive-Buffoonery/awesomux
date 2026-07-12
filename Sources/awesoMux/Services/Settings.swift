import Foundation

/// User-defaults keys for app preferences.
///
/// All keys here back to `~/Library/Preferences/<bundle-id>.plist`, which is
/// unencrypted and readable by any process running as the user.
///
/// **Do NOT add secrets here.** API keys, OAuth tokens, agent credentials, and
/// any other sensitive values must go through the Keychain (`Security.framework`
/// via `SecItemAdd` / `SecItemCopyMatching`), not UserDefaults. If you find
/// yourself adding a key whose name contains "key", "token", "secret", "password",
/// or "credential", stop and route it through a Keychain wrapper instead.
enum SettingsKey {
    static let theme = "settings.theme"
    static let accentColor = "settings.accentColor"
    static let glowStrength = "settings.glowStrength"
    static let notificationsMuted = "settings.notificationsMuted"
    static let notificationSoundEnabled = "settings.notificationSoundEnabled"
    static let respectDoNotDisturb = "settings.respectDoNotDisturb"
    static let rememberToolTrust = "settings.rememberToolTrust"
    static let defaultWorkspaceGroup = "settings.defaultWorkspaceGroup"
    static let outputMarksNeedsAttention = "settings.outputMarksNeedsAttention"
    /// Read via `SettingsDefault.resolvedUpdateChannel(from:)`, never
    /// `defaults.string(forKey:)` directly — the raw plist value isn't
    /// trustworthy (INT-164: a poisoned/stale string must reject, not
    /// silently propagate to whichever future updater consumer reads it).
    static let updateChannel = "settings.updateChannel"
    static let lastUpdateCheckEpoch = "settings.lastUpdateCheckEpoch"
    static let appKitStateRestorationEnabled = "settings.appKitStateRestorationEnabled"
}

enum SettingsDefault {
    static let theme = ThemePreference.system.rawValue
    static let accentColor = AccentColorPreference.peach.rawValue
    static let glowStrength: Double = 0.65
    static let notificationsMuted = false
    static let notificationSoundEnabled = true
    static let respectDoNotDisturb = true
    static let rememberToolTrust = true
    static let defaultWorkspaceGroup = "awesoMux"
    static let outputMarksNeedsAttention = true
    static let updateChannel = UpdateChannel.stable.rawValue
    static let lastUpdateCheckEpoch: Double = 0
    static let appKitStateRestorationEnabled = false

    /// Validated read of `SettingsKey.updateChannel`. `UpdateChannel` is a
    /// `RawRepresentable` enum backed by an unencrypted UserDefaults string
    /// (see `SettingsKey` doc comment) — a poisoned or stale value (e.g. from
    /// a downgrade, or manual plist editing) must not silently propagate as
    /// a raw string to whichever future updater consumer reads this key.
    /// Falls back to `.stable`, matching `SettingsDefault.updateChannel`.
    static func resolvedUpdateChannel(from defaults: UserDefaults = .standard) -> UpdateChannel {
        let rawValue = defaults.string(forKey: SettingsKey.updateChannel) ?? updateChannel
        return UpdateChannel(rawValue: rawValue) ?? .stable
    }

    static func registerInitialValues(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            SettingsKey.theme: theme,
            SettingsKey.accentColor: accentColor,
            SettingsKey.glowStrength: glowStrength,
            SettingsKey.notificationsMuted: notificationsMuted,
            SettingsKey.notificationSoundEnabled: notificationSoundEnabled,
            SettingsKey.respectDoNotDisturb: respectDoNotDisturb,
            SettingsKey.rememberToolTrust: rememberToolTrust,
            SettingsKey.defaultWorkspaceGroup: defaultWorkspaceGroup,
            SettingsKey.outputMarksNeedsAttention: outputMarksNeedsAttention,
            SettingsKey.updateChannel: updateChannel,
            SettingsKey.lastUpdateCheckEpoch: lastUpdateCheckEpoch,
            SettingsKey.appKitStateRestorationEnabled: appKitStateRestorationEnabled
        ])
    }
}
