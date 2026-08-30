import AwesoMuxCore
import Foundation

/// The main-actor reaction to a finished branch-diff render.
///
/// Split out of `showBranchChangesForActivePane` because the ORDER encoded here
/// is the correctness story, and inside a detached task's completion closure
/// nothing can observe it. Two rules, neither obvious from the call site:
///
/// 1. Bytes that reached disk are registered as awesoMux's own write *before*
///    any gate that can discard this run.
/// 2. The tab follows the PANE, not the workspace the render started in.
@MainActor
enum BranchChangesCompletion {
    /// - Parameter alert: injected rather than called directly because the
    ///   production alert is a modal `NSAlert`, which a test process cannot run.
    static func apply(
        _ result: Result<OpenedBranchChanges, BranchChangesFailure>,
        paneID: TerminalPane.ID,
        ticket: Int,
        store: SessionStore,
        alert: (BranchChangesFailure) -> Void
    ) {
        // Unconditional, and ahead of every gate below. The slot claim stops a
        // superseded run writing to the SAME slot, but two runs on one pane can
        // render into different slots — a branch switch between presses changes
        // the key — so a run whose UI reaction is about to be discarded can
        // still have put bytes on disk. Unregistered, those bytes make the
        // watcher on whatever tab already holds that file report awesoMux's own
        // rewrite as somebody else's edit, announced aloud to the one user who
        // has no way to check.
        // Gated by ticket so a stale completion arriving AFTER the current one
        // cannot re-register the path with older bytes than disk holds — the
        // mirror image of the unregistered-write bug the unconditional record
        // would reintroduce.
        if case .success(let opened) = result,
            BranchChangesInvocations.shouldRegister(ticket, for: opened.fileURL)
        {
            DocumentPaneView.selfWriteRegistry.record(
                fileURL: opened.fileURL,
                source: opened.markdown
            )
        }
        guard BranchChangesInvocations.isCurrent(ticket, paneID: paneID) else { return }

        switch result {
        case .failure(.superseded):
            // A newer invocation owns the slot and wrote it. Silent by design:
            // this run has no bytes on disk to open a tab onto, and the run that
            // does is the one the user is waiting for.
            return
        case .success(let opened):
            // The pane the diff was taken from has to still be there: the tab's
            // send/stage target is that pane, and the document's whole claim is
            // "these are the changes in THAT terminal". Resolved by pane id
            // across the store rather than against the workspace the press came
            // from — "Move Pane to New Workspace" keeps the pane id and changes
            // its owner, so a moved-but-live pane would otherwise be reported
            // closed and get no tab at all.
            guard let ownerID = store.sessionIDContainingPane(paneID) else {
                alert(.paneClosed)
                return
            }
            guard
                store.openDocumentPane(
                    fileURL: opened.fileURL,
                    in: ownerID,
                    associatedWith: paneID,
                    branchChangesIdentity: opened.identity
                ) != nil
            else {
                // The workspace went away while the diff ran. No alert — there
                // is nothing left to act on, and the user closed it themselves —
                // but silence would read as a dead command to anyone listening.
                TerminalAccessibilityAnnouncer.announce(
                    String(
                        localized: "The workspace closed before the changes could open.",
                        comment:
                            "VoiceOver announcement when a rendered branch diff has no workspace left to open into"
                    )
                )
                return
            }
            TerminalAccessibilityAnnouncer.announce(
                String(
                    localized: "Branch changes opened.",
                    comment:
                        "VoiceOver announcement after a rendered branch diff opens in a document tab"
                )
            )
        case .failure(let failure):
            alert(failure)
        }
    }
}
