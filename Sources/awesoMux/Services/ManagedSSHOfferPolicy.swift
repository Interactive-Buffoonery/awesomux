import AwesoMuxConfig
import AwesoMuxCore

enum ManagedSSHOfferPolicy {
    enum AddResult: Equatable {
        case added(String)
        case duplicate
        case invalid
    }

    static func shouldOffer(target: RemoteTarget, config: WorkspaceConfig) -> Bool {
        guard config.managedSSHOffersEnabled else { return false }
        return !normalizedIgnoredDestinations(in: config).contains(target.sshDestination)
    }

    static func addIgnoredDestination(
        _ text: String,
        to config: inout WorkspaceConfig
    ) -> AddResult {
        guard let destination = SSHWorkspaceDestinationValidation.target(from: text)?.sshDestination else {
            return .invalid
        }
        guard !normalizedIgnoredDestinations(in: config).contains(destination) else {
            return .duplicate
        }
        config.managedSSHOfferIgnoredDestinations.append(destination)
        return .added(destination)
    }

    static func removeIgnoredDestination(
        _ destination: String,
        from config: inout WorkspaceConfig
    ) {
        let normalized = SSHWorkspaceDestinationValidation.target(from: destination)?.sshDestination
        config.managedSSHOfferIgnoredDestinations.removeAll { stored in
            if let normalized {
                return SSHWorkspaceDestinationValidation.target(from: stored)?.sshDestination == normalized
            }
            return stored == destination
        }
    }

    private static func normalizedIgnoredDestinations(in config: WorkspaceConfig) -> Set<String> {
        Set(
            config.managedSSHOfferIgnoredDestinations.compactMap {
                SSHWorkspaceDestinationValidation.target(from: $0)?.sshDestination
            }
        )
    }
}
