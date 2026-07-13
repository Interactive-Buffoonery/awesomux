import Foundation

/// A declared SSH destination attached to a remote Workspace Group. This is
/// *declared* group state, distinct from `TerminalPane.remoteHost` (which is a
/// detected, disposable, title-derived signal on a live pane).
public struct RemoteTarget: Equatable, Hashable, Sendable {
    public var user: String
    public var host: String

    public init?(user: String, host: String) {
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
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
            guard let target = Self(user: String(trimmed[..<at]), host: host) else { return nil }
            self = target
        } else {
            guard let target = Self(user: "", host: trimmed) else { return nil }
            self = target
        }
    }

    /// The argument passed to `ssh`/`scp`: `user@host`, or just `host` when no
    /// user is declared (ssh resolves the user from config).
    public var sshDestination: String {
        user.isEmpty ? host : "\(user)@\(host)"
    }
}

extension RemoteTarget: Codable {
    private enum CodingKeys: String, CodingKey {
        case user
        case host
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let user = try container.decode(String.self, forKey: .user)
        let host = try container.decode(String.self, forKey: .host)
        guard let target = Self(user: user, host: host) else {
            throw DecodingError.dataCorruptedError(
                forKey: .host,
                in: container,
                debugDescription: "A remote target host cannot be empty."
            )
        }
        self = target
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(user, forKey: .user)
        try container.encode(host, forKey: .host)
    }
}
