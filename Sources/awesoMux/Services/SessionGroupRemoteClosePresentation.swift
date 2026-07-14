import AwesoMuxCore
import Foundation

struct SessionGroupRemoteClosePresentation {
    let lossText: String?

    var requiresConfirmation: Bool { lossText != nil }

    init(summary: SessionGroupExecutionSummary, isEmpty: Bool) {
        let activeRemoteText: String?
        switch summary.contents {
        case .empty, .localOnly:
            activeRemoteText = nil
        case .singleRemote(let target):
            activeRemoteText = String(
                localized: "Closing this group terminates remote panes on \(target.sshDestination).",
                comment: "Remote-impact line in the close-group confirmation for one SSH destination."
            )
        case .mixed(let targets, let includesLocal):
            let destinations = ListFormatter.localizedString(
                byJoining: targets.map(\.sshDestination)
            )
            activeRemoteText =
                includesLocal
                ? String(
                    localized: "Closing this group terminates local panes and remote panes on \(destinations).",
                    comment: "Remote-impact line in the close-group confirmation for mixed local and remote panes."
                )
                : String(
                    localized: "Closing this group terminates remote panes on \(destinations).",
                    comment: "Remote-impact line in the close-group confirmation for multiple SSH destinations."
                )
        }

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
