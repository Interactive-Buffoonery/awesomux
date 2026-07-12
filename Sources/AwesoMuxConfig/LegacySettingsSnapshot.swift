import os

private let legacyMigrationLogger = Logger(
    subsystem: "com.interactivebuffoonery.awesomux",
    category: "settings.migration"
)

public struct LegacySettingsSnapshot: Equatable, Sendable {
    public var theme: String?
    public var accentColor: String?
    public var glowStrength: Double?
    public var notificationsMuted: Bool?
    public var notificationSoundEnabled: Bool?
    public var respectDoNotDisturb: Bool?
    public var rememberToolTrust: Bool?
    public var defaultWorkspaceGroup: String?
    public var outputMarksNeedsAttention: Bool?

    public init(
        theme: String? = nil,
        accentColor: String? = nil,
        glowStrength: Double? = nil,
        notificationsMuted: Bool? = nil,
        notificationSoundEnabled: Bool? = nil,
        respectDoNotDisturb: Bool? = nil,
        rememberToolTrust: Bool? = nil,
        defaultWorkspaceGroup: String? = nil,
        outputMarksNeedsAttention: Bool? = nil
    ) {
        self.theme = theme
        self.accentColor = accentColor
        self.glowStrength = glowStrength
        self.notificationsMuted = notificationsMuted
        self.notificationSoundEnabled = notificationSoundEnabled
        self.respectDoNotDisturb = respectDoNotDisturb
        self.rememberToolTrust = rememberToolTrust
        self.defaultWorkspaceGroup = defaultWorkspaceGroup
        self.outputMarksNeedsAttention = outputMarksNeedsAttention
    }

    public func migratedConfig(defaults: AwesoMuxConfig = .defaultValue) -> AwesoMuxConfig {
        var config = defaults

        config.appearance.theme = migratedTheme(defaults.appearance.theme)
        config.appearance.accent = migratedAccent(defaults.appearance.accent)
        config.appearance.glowStrength = migratedGlowStrength(defaults.appearance.glowStrength)
        config.notifications.muted = notificationsMuted ?? defaults.notifications.muted
        config.notifications.sound = notificationSoundEnabled ?? defaults.notifications.sound
        config.notifications.respectDoNotDisturb = respectDoNotDisturb ?? defaults.notifications.respectDoNotDisturb
        config.agents.rememberToolTrust = rememberToolTrust ?? defaults.agents.rememberToolTrust
        config.workspaces.defaultGroup = defaultWorkspaceGroup ?? defaults.workspaces.defaultGroup
        config.workspaces.outputMarksNeedsAttention = outputMarksNeedsAttention
            ?? defaults.workspaces.outputMarksNeedsAttention

        return config
    }

    private func migratedTheme(_ defaultValue: AppearanceConfig.Theme) -> AppearanceConfig.Theme {
        switch theme {
        case nil:
            return defaultValue
        case "system":
            return .system
        case "mocha", "dark":
            return .dark
        case "latte", "light":
            return .light
        default:
            legacyMigrationLogger.notice(
                "Legacy theme value \"\(self.theme ?? "", privacy: .public)\" is unknown; falling back to default."
            )
            return defaultValue
        }
    }

    private func migratedAccent(_ defaultValue: AppearanceConfig.Accent) -> AppearanceConfig.Accent {
        guard let accentColor else { return defaultValue }
        guard let accent = AppearanceConfig.Accent(rawValue: accentColor) else {
            legacyMigrationLogger.notice(
                "Legacy accent value \"\(accentColor, privacy: .public)\" is unknown; falling back to default."
            )
            return defaultValue
        }
        return accent
    }

    private func migratedGlowStrength(_ defaultValue: Double) -> Double {
        guard let glowStrength else { return defaultValue }
        guard (0.0 ... 1.0).contains(glowStrength) else {
            legacyMigrationLogger.notice(
                "Legacy glow_strength \(glowStrength, privacy: .public) is outside 0.0...1.0; falling back to default."
            )
            return defaultValue
        }
        return glowStrength
    }
}
