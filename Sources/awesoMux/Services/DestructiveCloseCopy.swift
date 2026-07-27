import AwesoMuxCore
import Foundation

/// Confirmation copy for the closes that destroy something, kept honest about
/// what awesoMux can actually reach.
///
/// A pane declaring remote-owned zmx persistence (ADR-0023 amendment #214) has
/// no local daemon in front of it: its session belongs to the far host and
/// survives every local close by design. Promising to terminate it would be a
/// lie, and it is the reason these bodies are composed from whole sentences
/// instead of one string per variant — risk state times persistence ownership
/// is six bodies, of which only the persistence clause differs. Each sentence
/// still stands alone for translators.
enum DestructiveCloseCopy {
    /// The clause that keeps a close confirmation honest about panes whose
    /// session the remote host owns. Nil when no such pane is closing.
    static func remoteOwnedSurvivalLine(targets: [RemoteTarget]) -> String? {
        guard !targets.isEmpty else { return nil }
        let destinations = ListFormatter.localizedString(
            byJoining: targets.map(\.sshDestination)
        )
        return String(
            localized: "Panes on \(destinations) only disconnect; the remote host keeps their sessions running.",
            comment:
                "Close-confirmation line for panes whose zmx session the remote host owns. The argument is a list of SSH destinations."
        )
    }

    /// Body of the clear-workspace (permanent close) confirmation. The clear
    /// path kills the local `amx` daemon behind every pane, so it terminates
    /// local shells and local-amx SSH panes — and only disconnects the panes
    /// the far host owns.
    static func clearWorkspaceBody(
        title: String,
        hasInterruptedActivity: Bool,
        summary: SessionGroupExecutionSummary
    ) -> String {
        var sentences: [String] = [
            hasInterruptedActivity
                ? String(
                    localized:
                        "\(title) has activity that will be interrupted. The workspace will be closed permanently and can't be reopened.",
                    comment:
                        "Opening line of the clear-workspace confirmation dialog when the workspace has running activity. Argument is the bidi-isolated workspace title."
                )
                : String(
                    localized: "\(title) will be closed permanently and can't be reopened.",
                    comment:
                        "Opening line of the clear-workspace confirmation dialog. Argument is the bidi-isolated workspace title."
                )
        ]
        if summary.includesLocallyOwnedSessions {
            sentences.append(
                String(
                    localized: "The sessions awesoMux runs for it will be terminated.",
                    comment:
                        "Clear-workspace confirmation line covering the panes whose sessions a local daemon owns."
                )
            )
        }
        if let survivalLine = remoteOwnedSurvivalLine(targets: summary.remoteOwnedTargets) {
            sentences.append(survivalLine)
        }
        return sentences.joined(separator: " ")
    }
}
