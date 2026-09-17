import AwesoMuxCore
import Foundation
import Observation

/// In-flight latch for remote Markdown Refresh / restore re-fetch, keyed by
/// document tab.
///
/// Lives outside `DocumentPaneSendBar`'s `@State` because that bar remounts on
/// `DocumentNudgeSendBarID` (shell activity / agent kind / agent state). A
/// remount mid-SSH would clear a view-local busy flag, re-enable Refresh, and
/// let a second caller announce the coalesced fetch outcome again.
@MainActor
@Observable
final class RemoteMarkdownRefreshCoordinator {
    private(set) var refreshingDocumentIDs: Set<DocumentPane.ID> = []

    /// Claims the tab for one refresh. Returns `false` when another run for
    /// this tab is already in flight.
    @discardableResult
    func begin(documentID: DocumentPane.ID) -> Bool {
        refreshingDocumentIDs.insert(documentID).inserted
    }

    func finish(documentID: DocumentPane.ID) {
        refreshingDocumentIDs.remove(documentID)
    }

    func isRefreshing(_ documentID: DocumentPane.ID) -> Bool {
        refreshingDocumentIDs.contains(documentID)
    }
}
