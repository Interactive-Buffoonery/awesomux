import AwesoMuxCore
import Foundation

/// In-flight latch for Markdown→Markdown remote document opens, keyed by the
/// destination session plus resolved remote file.
///
/// The fetch layer already coalesces identical network requests, but each
/// click still runs the announce → apply → announce sequence on its own. A
/// second click while the first is in flight is dropped here so VoiceOver
/// hears one set of cues and only one focus request fires.
///
/// The footer Refresh owns a separate latch keyed by document tab
/// (`RemoteMarkdownRefreshCoordinator`); the two are intentionally independent,
/// so a Refresh racing a link open can still announce twice for one file.
@MainActor
final class RemoteMarkdownDocumentLinkCoordinator {
    static let shared = RemoteMarkdownDocumentLinkCoordinator()

    private struct Key: Hashable {
        let sessionID: TerminalSession.ID
        let identity: ResourceIdentity
    }

    private var inFlight: Set<Key> = []

    /// Claims the file for one open in a session. Returns `false` when another
    /// open for the same file in that session is already in flight.
    @discardableResult
    func begin(sessionID: TerminalSession.ID, identity: ResourceIdentity) -> Bool {
        inFlight.insert(Key(sessionID: sessionID, identity: identity)).inserted
    }

    func finish(sessionID: TerminalSession.ID, identity: ResourceIdentity) {
        inFlight.remove(Key(sessionID: sessionID, identity: identity))
    }
}
