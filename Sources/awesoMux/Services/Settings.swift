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
    static let appKitStateRestorationEnabled = "settings.appKitStateRestorationEnabled"
    /// Machine-owned "have they been shown the welcome tour" bit. UserDefaults
    /// rather than TOML deliberately: TOML is the hand-editable user surface
    /// and this is not a settings row. Never register a default for it —
    /// `FirstRunTourPolicy` seeds it exactly once by testing
    /// `object(forKey:) == nil`, and a registration entry would make that read
    /// non-nil forever (the registration domain is process-wide, so it would
    /// also leak across suites in tests).
    static let hasSeenFirstRunTour = "settings.hasSeenFirstRunTour"
}
