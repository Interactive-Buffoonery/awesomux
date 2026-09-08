import AwesoMuxConfig
import AwesoMuxCore

/// A remembered grant commits only when the workspace accepts the connection.
enum ManagedSSHConnectionPreference {
    case destination
    case allDestinations

    enum Result {
        case finished
        case saveFailed
        case rollbackFailed
    }
    @MainActor
    func submit(execution: SSHExecution, store: AppSettingsStore, connect: () -> Bool) -> Result {
        let before = store.workspaces.value
        var saved = before
        switch self {
        case .destination:
            _ = ManagedSSHOfferPolicy.addAlwaysManagedDestination(
                execution.target.sshDestination, sessionName: execution.sessionName, to: &saved
            )
        case .allDestinations:
            saved.managedSSHAlwaysManageAllDestinations = true
            saved.managedSSHOffersEnabled = true
        }
        store.workspaces.update { $0 = saved }
        guard store.workspaces.value == saved else { return .saveFailed }
        guard !connect() else { return .finished }

        let current = store.workspaces.value
        var restored = current
        rollback(before: before, saved: saved, execution: execution, current: &restored)
        guard restored != current else { return .finished }
        store.workspaces.update { $0 = restored }
        return store.workspaces.value == restored ? .finished : .rollbackFailed
    }

    /// Restore only this intent's fields while retaining edits made during submission.
    private func rollback(
        before: WorkspaceConfig, saved: WorkspaceConfig, execution: SSHExecution,
        current: inout WorkspaceConfig
    ) {
        switch self {
        case .destination:
            let destination = execution.target.sshDestination
            func matches(_ stored: String) -> Bool {
                SSHWorkspaceDestinationValidation.target(from: stored)?.sshDestination == destination
            }
            let savedEntries = saved.managedSSHAlwaysManaged.filter { matches($0.key) }
            let currentEntries = current.managedSSHAlwaysManaged.filter { matches($0.key) }
            let savedIgnored = saved.managedSSHOfferIgnoredDestinations.filter(matches)
            let currentIgnored = current.managedSSHOfferIgnoredDestinations.filter(matches)
            guard currentEntries == savedEntries, currentIgnored == savedIgnored else { return }
            current.managedSSHAlwaysManaged = current.managedSSHAlwaysManaged.filter { !matches($0.key) }
            current.managedSSHAlwaysManaged.merge(before.managedSSHAlwaysManaged.filter { matches($0.key) }) { _, old in old }
            current.managedSSHOfferIgnoredDestinations.removeAll(where: matches)
            for (index, entry) in before.managedSSHOfferIgnoredDestinations.enumerated() where matches(entry) {
                current.managedSSHOfferIgnoredDestinations.insert(entry, at: min(index, current.managedSSHOfferIgnoredDestinations.count))
            }
        case .allDestinations:
            if current.managedSSHAlwaysManageAllDestinations == saved.managedSSHAlwaysManageAllDestinations {
                current.managedSSHAlwaysManageAllDestinations = before.managedSSHAlwaysManageAllDestinations
            }
            if current.managedSSHOffersEnabled == saved.managedSSHOffersEnabled {
                current.managedSSHOffersEnabled = before.managedSSHOffersEnabled
            }
        }
    }
}
