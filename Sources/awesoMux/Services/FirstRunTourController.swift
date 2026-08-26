import Foundation

/// Whether the welcome tour should present itself unprompted.
///
/// `EmptyWorkspaceMode` alone cannot answer this: its own comment calls an
/// empty tree "cold launch / all-closed", closing the last group returns to
/// that state, and workspace restore being off makes it permanent. Install
/// age is a separate input.
enum FirstRunTourPolicy {
    static func shouldAutoPresent(
        hasSeenTour: Bool,
        hasPriorInstallEvidence: Bool,
        mode: EmptyWorkspaceMode
    ) -> Bool {
        guard !hasSeenTour, !hasPriorInstallEvidence else { return false }
        return mode == .firstLaunch
    }

    static func hasPriorInstallEvidence(
        snapshotExists: Bool,
        configDirectoryExists: Bool
    ) -> Bool {
        snapshotExists || configDirectoryExists
    }

    /// Written once, before the tour can ever evaluate. Without it an existing
    /// user upgrading into this build has the (false-by-default) flag and gets
    /// greeted as brand new.
    static func seedSeenFlagIfNeeded(
        defaults: UserDefaults = .standard,
        hasPriorInstallEvidence: Bool
    ) {
        guard hasPriorInstallEvidence else { return }
        defaults.set(true, forKey: SettingsKey.hasSeenFirstRunTour)
    }
}
