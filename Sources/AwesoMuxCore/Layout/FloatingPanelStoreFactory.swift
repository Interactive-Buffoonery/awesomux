import Foundation

/// Pure-logic helper for seeding a per-workspace floating-panel
/// `SessionStore`. Lives in `AwesoMuxCore` so the seeding rules
/// (title formatting, working-directory fallback, single-session
/// shape) can be unit-tested without standing up the AppKit-layer
/// `TerminalPanelController` and its `GhosttyRuntime` dependency.
@MainActor
public enum FloatingPanelStoreFactory {
    public static let groupName = "Floating Panel"
    public static let unattachedTitle = "floating panel"

    /// Exported (value `"1"`) into every surface spawned from a floating
    /// slot so shell rc files can tell the floating panel apart from a
    /// regular pane — the standard "am I in tmux/zellij?" env-var pattern.
    /// awesoMux only sets the marker; what a shell does with it (skip a
    /// fetch banner, shorten a prompt, nothing) is the user's call.
    nonisolated public static let spawnEnvironmentKey = "AWESOMUX_FLOATING_PANEL"

    /// Build a fresh single-session `SessionStore` for the floating
    /// panel. Title is `"floating · <parent>"` when a parent workspace
    /// is provided with a non-empty title, otherwise `"floating panel"`.
    /// Working directory falls back to `fallbackHome` (an absolute
    /// path) when the parent workspace is nil — never a literal `~`,
    /// which the working-directory validator rejects.
    public static func makeStore(
        parentWorkspace: TerminalSession?,
        fallbackHome: String
    ) -> SessionStore {
        let session = TerminalSession(
            title: makeTitle(parentWorkspace: parentWorkspace),
            workingDirectory: parentWorkspace?.workingDirectory ?? fallbackHome,
            agentKind: .shell,
            agentState: AgentKind.shell.initialSessionState
        )
        let store = SessionStore(
            groups: [
                SessionGroup(name: groupName, sessions: [session])
            ],
            selectedSessionID: session.id
        )
        store.compactTerminalKind = .floatingPanel
        return store
    }

    public static func makeTitle(parentWorkspace: TerminalSession?) -> String {
        guard let parentTitle = parentWorkspace?.title, !parentTitle.isEmpty else {
            return unattachedTitle
        }
        return "floating · \(parentTitle)"
    }
}
