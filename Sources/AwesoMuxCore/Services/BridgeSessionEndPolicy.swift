/// Reason for a session end (detach, daemon death, shell exit, or unknown).
public enum SessionEndReason: Equatable {
    case daemonDied
    case detached
    case shellExit
    case unknown
}

/// Command to execute when a session ends.
public enum BridgeSessionEndCommand: Equatable {
    /// Spawn a fresh respawn of the attach command (e.g., `amx attach <id>`).
    case respawnFresh
    /// Mark the pane as exited; do not reconnect or respawn.
    case markExited
    /// Attempt to reconnect to the existing session.
    case reconnect
    /// Mark as a fatal error state; do not recover.
    case error
}

/// Pure decision policy for what to do when a session ends.
///
/// Mirrors `BridgeSurfaceCommandPolicy`: branching lives here so it is
/// unit-testable instead of buried in an AppKit `NSView`.
public enum BridgeSessionEndPolicy {
    /// Decide what action to take when a bridge session ends.
    ///
    /// Decision order:
    /// 1. If respawn attempts >= max attempts → .error
    /// 2. If bridge is disabled → local .markExited, remote .error
    /// 3. If reason is nil, .unknown, or .daemonDied → .respawnFresh
    /// 4. If reason is .shellExit → local .markExited; remote .error only on ssh
    ///    transport failure (code 255) or an unknown code, else .markExited
    /// 5. If reason is .detached → .reconnect
    ///
    /// - Parameters:
    ///   - reason: The reason the session ended, or nil if unknown.
    ///   - bridgeEnabled: Whether the command-bridge is enabled.
    ///   - isRemote: Whether the pane belongs to a remote-tagged workgroup.
    ///   - exitCode: The session's exit code when known (ssh returns 0 on a
    ///     clean `exit`, 255 on a dropped connection). Only consulted for a
    ///     remote `.shellExit`; nil means unknown and is treated as abnormal.
    ///   - respawnAttempts: Number of respawn attempts so far.
    ///   - maxAttempts: Maximum allowed respawn attempts.
    /// - Returns: The action to take.
    public static func decide(
        reason: SessionEndReason?,
        bridgeEnabled: Bool,
        isRemote: Bool = false,
        exitCode: Int? = nil,
        respawnAttempts: Int,
        maxAttempts: Int
    ) -> BridgeSessionEndCommand {
        if respawnAttempts >= maxAttempts {
            return .error
        }

        // Bridge disabled → local shell semantics can end cleanly, but a remote
        // workgroup has no safe local fallback surface under ADR-0022.
        if !bridgeEnabled {
            return isRemote ? .error : .markExited
        }

        switch reason {
        // INT-571 validated that respawning on an unknown/missing signal is
        // safer than latching an error.
        case nil, .some(.unknown), .some(.daemonDied):
            return .respawnFresh
        // Shell exited. For local panes this is normal terminal lifecycle → close.
        // For remote panes, split on the exit code (INT-769). ssh forwards the
        // remote shell's own status, and reserves 255 for its transport-layer
        // failures. So a *deliberate* remote exit — `exit`, `exit 1`, any code the
        // remote shell chose — means the user left; close the pane like a local
        // shell. Only ssh's 255 (dropped connection) or an unknown/absent code
        // keeps the persistent workgroup and surfaces an error to reconnect from,
        // never auth-loop.
        case .some(.shellExit):
            guard isRemote else { return .markExited }
            return (exitCode == nil || exitCode == 255) ? .error : .markExited
        // User-initiated detach → attempt reconnect.
        case .some(.detached):
            return .reconnect
        }
    }
}
