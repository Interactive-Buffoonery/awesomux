import AwesoMuxConfig

/// Whether a managed-SSH preference can actually reach disk right now.
///
/// `AppSettingsStore.attemptPersist` deliberately reports success without
/// writing while the config file on disk is flagged invalid, so every
/// value-based "did the save land" check a sheet can make passes, the sheet
/// dismisses, and the preference is gone at next launch. Settings renders a
/// banner for that state — but a modal sheet covers it, so a sheet cannot rely
/// on the banner and has to refuse for itself.
///
/// Shared rather than duplicated: the first version of this guard went into the
/// connect sheet only, and the Settings add-destination sheet kept the identical
/// hole for exactly as long as nobody compared them.
@MainActor
enum ManagedSSHPreferenceWriteGuard {
    static func blockedReason(store: AppSettingsStore) -> String? {
        guard store.isDiskConfigInvalid else {
            return nil
        }
        return String(
            localized:
                "Your config file has an error, so this choice can’t be saved. Fix it in Settings › Advanced, then try again.",
            comment:
                "Error shown when a managed SSH preference cannot persist because the config file on disk is invalid"
        )
    }
}
