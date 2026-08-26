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
}
