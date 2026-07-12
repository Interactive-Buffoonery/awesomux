import AwesoMuxCore

/// The AppKit/libghostty adapter surface the ``CommandBridgeEnactor`` drives.
///
/// The enactor owns all command-bridge lifecycle *state* and *sequencing*; the
/// host owns the unsafe native effects (surface dispose, layer reset, remount)
/// and the pane/store identity the enactor reads and mutates. `GhosttySurfaceNSView`
/// is the sole conformer; the protocol exists to keep the enactor from reaching
/// into unrelated view members, not to admit a second implementation.
@MainActor
protocol CommandBridgeEnactorHost: AnyObject {
    var runtime: GhosttyRuntime { get }
    var sessionStore: SessionStore { get }
    var sessionID: TerminalSession.ID { get }
    var paneID: TerminalPane.ID { get set }
    var pane: TerminalPane { get set }
    var terminalIsFocused: Bool { get }
    /// `surface != nil` — whether a live native surface exists to dispose.
    var hasNativeSurface: Bool { get }
    /// Shared with the non-bridge exit path; the enactor reads/clears it but does
    /// not own it.
    var commandExitCache: CommandExitCache { get set }
    /// Set by the non-bridge `handleCommandFinished`; bridge heals only clear it.
    var shellCommandFinishedIdleLatched: Bool { get set }

    func disposeNativeSurface(resetHostedLayer: Bool)
    func remountFreshSurfaceAfterCommandBridgeHeal(_ recovery: SessionStore.CommandBridgePaneHealResult)
    /// Recursion-floor re-entry: the `.markExited` arm clears bridge state, then
    /// calls this so the exit takes the normal non-bridge close/recycle path.
    func closeAfterProcessExit(processAlive: Bool)
    func scheduleSurfaceCreationIfNeeded()
}

extension GhosttySurfaceNSView: CommandBridgeEnactorHost {}
