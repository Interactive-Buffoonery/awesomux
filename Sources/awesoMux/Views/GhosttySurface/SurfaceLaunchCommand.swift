/// What a surface creation was decided to spawn: the command string plus the
/// one distinction the post-spawn bookkeeping needs — whether the pane is
/// attached to the LOCAL `amx` daemon.
///
/// Post-spawn bookkeeping also consults persistence ownership: a remote carrier
/// is local-daemon-backed but must not publish a local shell's cwd metadata.
enum SurfaceLaunchCommand: Equatable {
    /// Plain local login shell; `createSurface(command: nil)`.
    case localShell
    /// `amx attach <id>` against the local daemon, optionally wrapped by the
    /// D1/D4 bridge preflight.
    case bridgeAttach(String)
    /// Direct `ssh … zmx attach <name>` fallback without a local carrier.
    /// Its exit status uses a separate file instead of the amx status feed.
    case remoteOwnedAttach(String)

    var command: String? {
        switch self {
        case .localShell: nil
        case .bridgeAttach(let command), .remoteOwnedAttach(let command): command
        }
    }
}
