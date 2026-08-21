import AwesoMuxConfig
import AwesoMuxCore

enum ManagedSSHOfferPolicy {
    enum AddResult: Equatable {
        case added(String)
        case duplicate
        case invalid
    }

    /// What happens when an SSH connection to a destination is detected.
    /// The two lists are kept disjoint: adding a destination to one list
    /// removes it from the other, so the most recent choice takes precedence.
    enum OfferDecision: Equatable {
        case connectAutomatically
        case offer
        case none
    }

    static func decision(target: RemoteTarget, config: WorkspaceConfig) -> OfferDecision {
        if config.managedSSHAlwaysManageAllDestinations
            || isAlwaysManaged(target: target, config: config)
        {
            return .connectAutomatically
        }
        guard config.managedSSHOffersEnabled,
            !isIgnored(target: target, config: config)
        else { return .none }
        return .offer
    }

    static func isIgnored(target: RemoteTarget, config: WorkspaceConfig) -> Bool {
        normalizedIgnoredDestinations(in: config).contains(target.sshDestination)
    }

    static func isAlwaysManaged(target: RemoteTarget, config: WorkspaceConfig) -> Bool {
        normalizedAlwaysManagedDestinations(in: config).contains(target.sshDestination)
    }

    static func addIgnoredDestination(
        _ text: String,
        to config: inout WorkspaceConfig
    ) -> AddResult {
        guard let destination = validDestination(from: text) else {
            return .invalid
        }
        removeAlwaysManagedDestination(destination, from: &config)
        guard !normalizedIgnoredDestinations(in: config).contains(destination) else {
            return .duplicate
        }
        config.managedSSHOfferIgnoredDestinations.append(destination)
        return .added(destination)
    }

    static func addAlwaysManagedDestination(
        _ text: String,
        to config: inout WorkspaceConfig
    ) -> AddResult {
        guard let destination = validDestination(from: text) else {
            return .invalid
        }
        removeIgnoredDestination(destination, from: &config)
        guard !normalizedAlwaysManagedDestinations(in: config).contains(destination) else {
            return .duplicate
        }
        config.managedSSHAlwaysManagedDestinations.append(destination)
        return .added(destination)
    }

    static func removeIgnoredDestination(
        _ destination: String,
        from config: inout WorkspaceConfig
    ) {
        config.managedSSHOfferIgnoredDestinations.removeAll { stored in
            storedIdentity(stored, matches: destination)
        }
    }

    static func removeAlwaysManagedDestination(
        _ destination: String,
        from config: inout WorkspaceConfig
    ) {
        config.managedSSHAlwaysManagedDestinations.removeAll { stored in
            storedIdentity(stored, matches: destination)
        }
    }

    private static func validDestination(from text: String) -> String? {
        SSHWorkspaceDestinationValidation.target(from: text)?.sshDestination
    }

    private static func storedIdentity(_ stored: String, matches destination: String) -> Bool {
        if let normalized = SSHWorkspaceDestinationValidation.target(from: destination)?.sshDestination {
            return SSHWorkspaceDestinationValidation.target(from: stored)?.sshDestination == normalized
        }
        return stored == destination
    }

    private static func normalizedIgnoredDestinations(in config: WorkspaceConfig) -> Set<String> {
        Set(
            config.managedSSHOfferIgnoredDestinations.compactMap {
                SSHWorkspaceDestinationValidation.target(from: $0)?.sshDestination
            }
        )
    }

    private static func normalizedAlwaysManagedDestinations(in config: WorkspaceConfig) -> Set<String> {
        Set(
            config.managedSSHAlwaysManagedDestinations.compactMap {
                SSHWorkspaceDestinationValidation.target(from: $0)?.sshDestination
            }
        )
    }
}
