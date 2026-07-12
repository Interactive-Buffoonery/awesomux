import Foundation

public extension LegacySettingsSnapshot {
    init(userDefaults defaults: UserDefaults) {
        self.init(
            theme: defaults.string(forKey: LegacySettingsKey.theme),
            accentColor: defaults.string(forKey: LegacySettingsKey.accentColor),
            glowStrength: defaults.object(forKey: LegacySettingsKey.glowStrength) as? Double,
            notificationsMuted: defaults.object(forKey: LegacySettingsKey.notificationsMuted) as? Bool,
            notificationSoundEnabled: defaults.object(forKey: LegacySettingsKey.notificationSoundEnabled) as? Bool,
            respectDoNotDisturb: defaults.object(forKey: LegacySettingsKey.respectDoNotDisturb) as? Bool,
            rememberToolTrust: defaults.object(forKey: LegacySettingsKey.rememberToolTrust) as? Bool,
            defaultWorkspaceGroup: defaults.string(forKey: LegacySettingsKey.defaultWorkspaceGroup),
            outputMarksNeedsAttention: defaults.object(forKey: LegacySettingsKey.outputMarksNeedsAttention) as? Bool
        )
    }

    init?(persistedUserDefaults defaults: UserDefaults, domainName: String? = Bundle.main.bundleIdentifier) {
        guard let domainName,
              let domain = defaults.persistentDomain(forName: domainName),
              domain.keys.contains(where: LegacySettingsKey.allKeys.contains)
        else {
            return nil
        }

        // Sentinel set after a successful migration. Honors the
        // "downgrade-then-delete-config-then-upgrade" recovery path:
        // once we've migrated this domain into TOML, we never re-migrate
        // from it, even if config.toml is later removed. Without this
        // gate, deleting config.toml in v2 (which now means "reset to
        // defaults") would silently re-migrate from stale v1
        // UserDefaults the next time bootstrap ran.
        if domain[LegacySettingsKey.migratedToTOMLv2] as? Bool == true {
            return nil
        }

        self.init(
            theme: domain[LegacySettingsKey.theme] as? String,
            accentColor: domain[LegacySettingsKey.accentColor] as? String,
            glowStrength: domain[LegacySettingsKey.glowStrength] as? Double,
            notificationsMuted: domain[LegacySettingsKey.notificationsMuted] as? Bool,
            notificationSoundEnabled: domain[LegacySettingsKey.notificationSoundEnabled] as? Bool,
            respectDoNotDisturb: domain[LegacySettingsKey.respectDoNotDisturb] as? Bool,
            rememberToolTrust: domain[LegacySettingsKey.rememberToolTrust] as? Bool,
            defaultWorkspaceGroup: domain[LegacySettingsKey.defaultWorkspaceGroup] as? String,
            outputMarksNeedsAttention: domain[LegacySettingsKey.outputMarksNeedsAttention] as? Bool
        )
    }

    /// Mark the legacy UserDefaults domain as migrated so a future bootstrap
    /// after config.toml deletion does not re-migrate from stale state.
    ///
    /// Writes the sentinel into the persistent domain named by
    /// `domainName` so the read-side (`init?(persistedUserDefaults:domainName:)`)
    /// actually sees it. The earlier shape used `defaults.set(_:forKey:)`,
    /// which silently ignores the requested domain and writes to the
    /// standard one — meaning any caller using a non-default domain
    /// would never see the sentinel and the legacy migration could run
    /// again after a config reset.
    static func markMigratedToTOMLv2(
        in defaults: UserDefaults = .standard,
        domainName: String? = Bundle.main.bundleIdentifier
    ) {
        guard let domainName else {
            defaults.set(true, forKey: LegacySettingsKey.migratedToTOMLv2)
            return
        }

        var domain = defaults.persistentDomain(forName: domainName) ?? [:]
        domain[LegacySettingsKey.migratedToTOMLv2] = true
        defaults.setPersistentDomain(domain, forName: domainName)
    }
}

private enum LegacySettingsKey {
    static let theme = "settings.theme"
    static let accentColor = "settings.accentColor"
    static let glowStrength = "settings.glowStrength"
    static let notificationsMuted = "settings.notificationsMuted"
    static let notificationSoundEnabled = "settings.notificationSoundEnabled"
    static let respectDoNotDisturb = "settings.respectDoNotDisturb"
    static let rememberToolTrust = "settings.rememberToolTrust"
    static let defaultWorkspaceGroup = "settings.defaultWorkspaceGroup"
    static let outputMarksNeedsAttention = "settings.outputMarksNeedsAttention"
    static let migratedToTOMLv2 = "settings._migratedToTOMLv2"

    static let allKeys = [
        theme,
        accentColor,
        glowStrength,
        notificationsMuted,
        notificationSoundEnabled,
        respectDoNotDisturb,
        rememberToolTrust,
        defaultWorkspaceGroup,
        outputMarksNeedsAttention
    ]
}
