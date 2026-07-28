import AwesoMuxCore
import Foundation

/// Resolves the Connect via SSH sheet's fields into the execution they declare.
/// The Connect button's enabled state and the submit path both read
/// `execution(...)`, so "offered" and "accepted" cannot drift apart.
///
/// An entered session name means the REMOTE host owns the session, which is
/// what the persistence owner records.
enum SSHWorkspaceConnectFields {
    /// Nil whenever any entered field is invalid. Whitespace is trimmed first so
    /// a pasted `" my-session "` connects instead of reading as a bad name.
    static func execution(
        destination: String,
        sessionName rawSessionName: String
    ) -> SSHExecution? {
        guard let target = SSHWorkspaceDestinationValidation.target(from: destination) else { return nil }
        let trimmedName = rawSessionName.trimmingCharacters(in: .whitespaces)
        // No session name is the local-amx default: awesoMux keeps the session
        // alive on this side of the connection.
        guard !trimmedName.isEmpty else { return SSHExecution(target: target) }
        guard let sessionName = RemoteSessionName(rawValue: trimmedName) else { return nil }
        return SSHExecution(
            target: target,
            persistenceOwner: .remoteZmx,
            sessionName: sessionName
        )
    }

    /// True when the fields name a session the remote host owns, before the
    /// rest of the sheet's input is known to be valid — the copy that promises
    /// to enable background sessions keys off this, not off a full submission.
    static func declaresRemoteSession(sessionName: String) -> Bool {
        !sessionName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Names its field: it shares one message slot with the destination's, so
    /// heard out of visual context an unprefixed message would not say which
    /// field it is about.
    static func sessionNameMessage(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, RemoteSessionName(rawValue: trimmed) == nil else { return nil }
        return String(
            localized:
                "Session name: use up to \(RemoteSessionName.maxLength) letters, numbers, dots, dashes, or underscores. It can’t start with a dash or be “.” or “..”.",
            comment:
                "Validation message when a remote session name is invalid. The argument is the maximum number of characters."
        )
    }
}
