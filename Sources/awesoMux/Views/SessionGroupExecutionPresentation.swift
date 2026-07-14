import AwesoMuxCore
import Foundation

struct SessionGroupExecutionPresentation: Equatable {
    let visibleText: String?
    let accessibilityText: String

    init(summary: SessionGroupExecutionSummary) {
        switch summary.contents {
        case .empty:
            if let target = summary.defaultTarget?.sshDestination {
                visibleText = String(
                    localized: "SSH default · \(target)",
                    comment: "Location summary for an empty workspace group with an SSH creation default."
                )
                accessibilityText = String(
                    localized: "SSH creation default \(target), no active remote panes",
                    comment: "VoiceOver location summary for an empty workspace group with an SSH creation default."
                )
            } else {
                visibleText = nil
                accessibilityText = String(
                    localized: "Local creation default",
                    comment: "VoiceOver location summary for an empty local workspace group."
                )
            }
        case .localOnly:
            if let target = summary.defaultTarget?.sshDestination {
                visibleText = String(
                    localized: "Local · SSH default \(target)",
                    comment: "Location summary for local panes in a group that retains an SSH creation default."
                )
                accessibilityText = String(
                    localized: "Local panes, SSH creation default \(target)",
                    comment: "VoiceOver location summary for local panes in a group that retains an SSH creation default."
                )
            } else {
                visibleText = nil
                accessibilityText = String(
                    localized: "Local panes",
                    comment: "VoiceOver location summary for a workspace group containing only local panes."
                )
            }
        case .singleRemote(let target):
            visibleText = String(
                localized: "SSH · \(target.sshDestination)",
                comment: "Location summary for panes that all run on one declared SSH destination."
            )
            accessibilityText = String(
                localized: "Remote panes on \(target.sshDestination)",
                comment: "VoiceOver location summary for panes that all run on one declared SSH destination."
            )
        case .mixed(let targets, let includesLocal):
            visibleText = String(
                localized: "Mixed locations",
                comment: "Location summary for panes running in more than one local or remote location."
            )
            let destinations = ListFormatter.localizedString(
                byJoining: targets.map(\.sshDestination)
            )
            accessibilityText =
                includesLocal
                ? String(
                    localized: "Local and remote panes on \(destinations)",
                    comment: "VoiceOver location summary for a group with local and remote panes."
                )
                : String(
                    localized: "Remote panes on \(destinations)",
                    comment: "VoiceOver location summary for a group with more than one remote destination."
                )
        }
    }
}
