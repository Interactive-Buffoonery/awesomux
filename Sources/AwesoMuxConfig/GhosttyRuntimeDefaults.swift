public enum GhosttyRuntimeDefaults {
    /// Ghostty's `scrollback-limit` is bytes per terminal surface. Upstream
    /// defaults to 10MB; awesoMux starts lower so many-workspace sessions have
    /// a predictable ceiling while still leaving substantial text history.
    public static let scrollbackLimit = 5_000_000

    /// Loaded BEFORE `ghostty_config_load_default_files`, so anything the user
    /// sets in Ghostty's default config files wins (libghostty is last-write-wins).
    /// These are suggestions awesoMux ships as a starting point — the user
    /// remains the source of truth for their own machine. See INT-396.
    public static var defaultConfigContents: String {
        [
            "scrollback-limit = \(scrollbackLimit)"
        ].joined(separator: "\n") + "\n"
    }
}
