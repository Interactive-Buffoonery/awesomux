import Foundation
@testable import AwesoMuxCore

/// Test-only convenience: build a pane-keyed sync snapshot for a session's
/// ACTIVE pane. The write-side mirror of `TerminalSessionActivePaneTestSupport`
/// — it removes only the `sessionID:paneID:` boilerplate, keeping the pane-keyed
/// snapshot visible at the call site so tests drive the same interface
/// production does. Multi-pane fixtures construct snapshots by hand; this is for
/// the single-active-pane common case only.
extension ShellActivitySnapshot {
    static func active(_ session: TerminalSession, isBusy: Bool) -> ShellActivitySnapshot {
        ShellActivitySnapshot(sessionID: session.id, paneID: session.activePaneID, isBusy: isBusy)
    }
}

extension TerminalQuitConfirmationSnapshot {
    static func active(
        _ session: TerminalSession,
        needsConfirmation: Bool,
        liveness: ForegroundProcessLiveness = .unsampled
    ) -> TerminalQuitConfirmationSnapshot {
        TerminalQuitConfirmationSnapshot(
            sessionID: session.id,
            paneID: session.activePaneID,
            needsConfirmation: needsConfirmation,
            liveness: liveness
        )
    }
}
