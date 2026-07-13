import AwesoMuxCore

/// Shared gate for every sheet that accepts an SSH destination: a target only
/// comes back when the text both parses and passes `isSafeSSHDestination`, so
/// option-like input (`-oProxyCommand=…`) can never reach a create button.
enum SSHWorkspaceDestinationValidation {
    static func target(from text: String) -> RemoteTarget? {
        guard let target = RemoteTarget(parsing: text), target.isSafeSSHDestination else { return nil }
        return target
    }

    static func message(for text: String) -> String? {
        guard !text.isEmpty, target(from: text) == nil else { return nil }
        return String(
            localized: "Enter an SSH alias, hostname, or user@host, not a command option.",
            comment: "Validation message when a managed SSH workspace destination is invalid"
        )
    }
}
