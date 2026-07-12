import Foundation

/// A declared SSH destination attached to a remote Workspace Group. This is
/// *declared* group state, distinct from `TerminalPane.remoteHost` (which is a
/// detected, disposable, title-derived signal on a live pane).
public struct RemoteTarget: Codable, Equatable, Hashable, Sendable {
    public var user: String
    public var host: String

    public init(user: String, host: String) {
        self.user = user
        self.host = host
    }

    /// Parses `user@host` or a bare `host`. Splits on the LAST `@` so a username
    /// is optional. Returns nil when the host is empty (there is nothing to ssh
    /// to). Does not validate the host beyond non-emptiness — ssh + the user's
    /// config are the authority on whether it resolves.
    public init?(parsing raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let at = trimmed.lastIndex(of: "@") {
            let host = String(trimmed[trimmed.index(after: at)...])
            guard !host.isEmpty else { return nil }
            self.init(user: String(trimmed[..<at]), host: host)
        } else {
            self.init(user: "", host: trimmed)
        }
    }

    /// The argument passed to `ssh`/`scp`: `user@host`, or just `host` when no
    /// user is declared (ssh resolves the user from config).
    public var sshDestination: String {
        user.isEmpty ? host : "\(user)@\(host)"
    }
}
