import AwesoMuxCore
import UnicodeHygiene

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
        sessionName rawSessionName: String,
        remoteExecutablePath rawExecutablePath: String
    ) -> SSHExecution? {
        guard let target = SSHWorkspaceDestinationValidation.target(from: destination) else { return nil }
        let trimmedName = rawSessionName.trimmingCharacters(in: .whitespaces)
        // No session name is the local-amx default: awesoMux keeps the session
        // alive on this side of the connection, and the path field is not shown.
        guard !trimmedName.isEmpty else { return SSHExecution(target: target) }
        guard let sessionName = RemoteSessionName(rawValue: trimmedName) else { return nil }
        let trimmedPath = rawExecutablePath.trimmingCharacters(in: .whitespaces)
        return SSHExecution(
            target: target,
            persistenceOwner: .remoteZmx,
            sessionName: sessionName,
            remoteExecutablePath: trimmedPath.isEmpty ? nil : trimmedPath
        )
    }

    /// True when the fields name a session the remote host owns, before the
    /// rest of the sheet's input is known to be valid — the copy that promises
    /// to enable background sessions keys off this, not off a full submission.
    static func declaresRemoteSession(sessionName: String) -> Bool {
        !sessionName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func sessionNameMessage(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, RemoteSessionName(rawValue: trimmed) == nil else { return nil }
        return String(
            localized: "Use up to 64 letters, numbers, dots, dashes, or underscores.",
            comment: "Validation message when a remote zmx session name is invalid"
        )
    }

    /// Mirrors the path rule `SSHExecution` enforces, so a rejected path always
    /// explains itself instead of silently leaving Connect disabled.
    static func remoteExecutablePathMessage(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
            !trimmed.hasPrefix("/") || UnicodeHygiene.containsUnsafePathScalars(trimmed)
        else {
            return nil
        }
        return String(
            localized: "Enter an absolute path to zmx on the remote host.",
            comment: "Validation message when the remote zmx executable path is not a usable absolute path"
        )
    }
}
