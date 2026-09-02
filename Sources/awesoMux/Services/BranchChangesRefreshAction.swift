import AwesoMuxCore
import SwiftUI

/// The app's Show Branch Changes command, addressed by pane so a document tab
/// can refresh for the terminal it came from rather than the active one.
///
/// Delivered through the environment because the command needs the app's
/// `BranchChangesCoordinator` (the ticket authority for latest-wins), the
/// session store, and the failure-alert presenter — none of which the send bar
/// holds, and none of which should become a global to reach it.
struct BranchChangesRefreshAction {
    /// - Parameter originatingDocumentID: the tab that asked, when a tab did.
    ///   Nil for the menu and palette, which have no tab of their own and always
    ///   open one. A footer Refresh passes its tab so a run whose tab was closed
    ///   mid-flight finishes its cache write without reopening the tab the user
    ///   just dismissed.
    let run:
        @MainActor (
            _ paneID: TerminalPane.ID,
            _ originatingDocumentID: DocumentPane.ID?,
            _ completion: @escaping @MainActor () -> Void
        ) -> Void
}

extension EnvironmentValues {
    @Entry var branchChangesRefresh: BranchChangesRefreshAction?
}

enum BranchChangesRefreshPolicy {
    enum Verdict: Equatable {
        case ready
        case busy
        case unavailable(String)
    }

    static func verdict(target: DocumentNudgeTargetResolution, inFlight: Bool) -> Verdict {
        switch target {
        case .available:
            return inFlight ? .busy : .ready
        case .unavailable(.requiresLocalTerminal):
            return .unavailable(
                String(
                    localized: "Refresh needs a local terminal",
                    comment:
                        "Caption under a disabled Refresh button on a branch changes tab whose terminal is remote"
                )
            )
        case .unavailable:
            // Every other reason — including `.readOnlyRemoteSnapshot`, which a
            // locally generated diff cannot be — means there is no terminal left
            // to re-run against.
            return .unavailable(
                String(
                    localized: "This tab's terminal was closed",
                    comment:
                        "Caption under a disabled Refresh button on a branch changes tab whose terminal no longer exists"
                )
            )
        }
    }
}
