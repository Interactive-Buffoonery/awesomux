import AwesoMuxCore

/// Shared gate for every sheet that accepts an SSH destination. `RemoteTarget`
/// rejects option-like input (`-oProxyCommand=…`) before it can reach a create
/// button.
enum SSHWorkspaceDestinationValidation {
    static func target(from text: String) -> RemoteTarget? {
        RemoteTarget(parsing: text)
    }

    static func message(for text: String) -> String? {
        guard !text.isEmpty, target(from: text) == nil else { return nil }
        return String(
            localized: "Enter an SSH alias, hostname, or user@host, not a command option.",
            comment: "Validation message when a managed SSH workspace destination is invalid"
        )
    }
}
