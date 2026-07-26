/// What a surface creation was decided to spawn: the command string plus the
/// one distinction the post-spawn bookkeeping needs — whether the pane is
/// attached to the LOCAL `amx` daemon.
///
/// A bare `String?` cannot carry that. `established` backend metadata (which
/// gates the `amx cwd` poll and the deferred create-vs-reattach signal) is only
/// true of a local-amx attach, but a remote-owned pane also spawns with a
/// non-nil command — so "command != nil" would stamp metadata naming a local
/// session that does not exist, and the poll would query it every ~4s forever.
enum SurfaceLaunchCommand: Equatable {
    /// Plain local login shell; `createSurface(command: nil)`.
    case localShell
    /// `amx attach <id>` against the local daemon, optionally wrapped by the
    /// D1/D4 bridge preflight.
    case bridgeAttach(String)
    /// `ssh … zmx attach <name>`: the far host owns the session, so there is no
    /// local daemon, no status side channel, and nothing for the bridge to wrap.
    case remoteOwnedAttach(String)

    var command: String? {
        switch self {
        case .localShell: nil
        case .bridgeAttach(let command), .remoteOwnedAttach(let command): command
        }
    }
}
