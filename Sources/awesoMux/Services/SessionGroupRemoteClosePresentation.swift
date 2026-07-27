import AwesoMuxCore
import Foundation

struct SessionGroupRemoteClosePresentation {
    let lossText: String?

    var requiresConfirmation: Bool { lossText != nil }

    /// Closing a group soft-closes its workspaces: it never kills the local
    /// `amx` daemons, but reopening mints fresh session ids, so the panes those
    /// daemons hold are gone for the user either way. Panes the far host owns
    /// are the exception — their session keeps running under its declared name
    /// (ADR-0023 amendment #214), so the copy must not sweep them into the same
    /// sentence.
    init(summary: SessionGroupExecutionSummary, isEmpty: Bool) {
        let localAmxDestinations = ListFormatter.localizedString(
            byJoining: summary.localAmxTargets.map(\.sshDestination)
        )
        let localAmxText: String? =
            summary.localAmxTargets.isEmpty
            ? nil
            : String(
                localized:
                    "Closing this group closes remote panes on \(localAmxDestinations); awesoMux can't reattach them.",
                comment:
                    "Remote-impact line in the close-group confirmation for panes a local daemon keeps alive. The argument is a list of SSH destinations."
            )
        let remoteLines = [
            localAmxText,
            DestructiveCloseCopy.remoteOwnedSurvivalLine(targets: summary.remoteOwnedTargets),
        ].compactMap { $0 }
        let activeRemoteText: String? = remoteLines.isEmpty ? nil : remoteLines.joined(separator: " ")

        guard let defaultTarget = summary.defaultTarget?.sshDestination else {
            lossText = activeRemoteText
            return
        }

        let defaultText: String
        if activeRemoteText != nil {
            defaultText = String(
                localized: "It also removes the SSH creation default \(defaultTarget).",
                comment: "SSH-default loss line appended to a close-group confirmation with active remote panes."
            )
        } else if isEmpty {
            defaultText = String(
                localized: "Removing this group removes its SSH creation default \(defaultTarget). No active remote panes are affected.",
                comment: "SSH-default loss line for removing an empty workspace group."
            )
        } else {
            defaultText = String(
                localized: "Closing this group removes its SSH creation default \(defaultTarget). Its panes are local.",
                comment: "SSH-default loss line for closing a populated group whose panes are all local."
            )
        }

        lossText = [activeRemoteText, defaultText]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}
