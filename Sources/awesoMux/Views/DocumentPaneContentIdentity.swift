import AwesoMuxCore
import Foundation

/// Remount and "Now showing" policy for document pane content.
///
/// Local tabs remount when the on-disk path changes (file-browser navigation
/// on the same tab is a different document). Remote Markdown tabs remount on
/// tab identity instead: restore/Refresh can move the same remote identity
/// between a cache slot and a `.failure.md` slot, which must not look like a
/// tab switch to VoiceOver.
enum DocumentPaneContentIdentity {
    static func remountID(for document: DocumentPane) -> String {
        if document.remoteResourceIdentity != nil {
            return "remote-tab:\(document.id.uuidString)"
        }
        return document.fileURL.standardizedFileURL.path
    }
}

enum DocumentShownAnnouncementPolicy {
    /// Whether a content-key change should speak "Now showing {title}".
    ///
    /// Same remote identity means a cache↔failure (or fresh rewrite) slot move
    /// for the tab already on screen — announce the refresh outcome instead.
    static func shouldAnnounceNowShowing(
        previousRemoteIdentity: ResourceIdentity?,
        currentRemoteIdentity: ResourceIdentity?
    ) -> Bool {
        if let previous = previousRemoteIdentity,
            let current = currentRemoteIdentity,
            previous == current
        {
            return false
        }
        return true
    }
}
