import AwesoMuxBridgeProtocol
import AwesoMuxCore
import SwiftUI

struct GhosttySurfaceRepresentable: NSViewRepresentable {
    let session: TerminalSession
    let pane: TerminalPane
    let sessionStore: SessionStore
    let runtime: GhosttyRuntime
    let enabledAgentRuntimeFileDropSources: Set<AgentRuntimeSource>
    /// Whether a text-detected `grok` session may show the Grok sidebar icon.
    /// Backed by the same Settings opt-in that enables Grok runtime events.
    let grokIconEnabled: Bool
    /// Initial size for the upstream-shaped scroll wrapper. Runtime sizing is
    /// driven by `GhosttySurfaceContainerView.layout()`, matching Ghostty's
    /// macOS `SurfaceRepresentable` / `SurfaceScrollView` split.
    let contentSize: CGSize
    /// Snapshot of `GhosttyRuntime.surfaceRemountNudgeRevision`. Stored so a
    /// bump changes this struct's value and SwiftUI re-runs `updateNSView`,
    /// letting `mount()` re-adopt a surface view orphaned by split-collapse
    /// container churn (INT-600). Never read directly — its only job is to
    /// differ.
    let remountNudge: UInt64

    func makeNSView(context: Context) -> GhosttySurfaceContainerView {
        GhosttySurfaceContainerView(contentSize: contentSize)
    }

    func updateNSView(_ nsView: GhosttySurfaceContainerView, context: Context) {
        // The INT-600 collapse churn can hand the OUTGOING split subtree one
        // more update pass carrying the stale layout — after the closed pane's
        // surface was already discarded. Creating a surface view here would
        // resurrect a zombie cache entry (and eventually a shell) for a dead
        // pane, so only create/mount for panes the live layout still contains.
        guard Self.paneIsLive(paneID: pane.id, sessionID: session.id, in: sessionStore) else {
            return
        }
        let surfaceView = runtime.surfaceView(
            sessionStore: sessionStore,
            session: session,
            pane: pane,
            enabledAgentRuntimeFileDropSources: enabledAgentRuntimeFileDropSources,
            grokIconEnabled: grokIconEnabled
        )
        nsView.mount(
            surfaceView,
            isActive: session.activePaneID == pane.id,
            contentSize: contentSize
        )
    }

    static func paneIsLive(
        paneID: TerminalPane.ID,
        sessionID: TerminalSession.ID,
        in sessionStore: SessionStore
    ) -> Bool {
        sessionStore.session(id: sessionID)?.layout.pane(id: paneID) != nil
    }
}
