/// Whether a freshly-created terminal surface should run the command-bridge
/// (`amx attach <id>`) or a plain local shell.
public enum BridgeSurfaceCommand: Equatable {
    /// Run `amx attach <id>`. zmx creates the session if its daemon is gone,
    /// so this is also the recovery path for a dead daemon — no pre-attach
    /// existence check, no error latch.
    case bridgeAttach
    /// Run a normal login shell: the bridge is disabled, or no `amx` attach
    /// command could be built (e.g. the bundled binary is missing).
    case localShell
    /// A remote-tagged group whose attach command could not be built — the
    /// bundled `amx` is missing, OR the command bridge is globally disabled
    /// (a disabled bridge means no `amx attach`, so a remote group has no way
    /// to reach its host). Must surface an error, never a local shell: a local
    /// shell masquerading as the remote host is the ADR-0022 trust violation.
    case remoteUnavailable
    /// Run `zmx attach <name>` on the remote host itself. The far side owns the
    /// session, so there is no local `amx` daemon in the picture and no bridge
    /// to wrap — the pane is an ssh child whose persistence survives on the
    /// host, not in this app.
    case remoteOwnedAttach
}

/// Pure decision for `createSurfaceIfNeeded`. Mirrors `QuitRiskPolicy`: the
/// branching lives here so it is unit-testable instead of buried in an AppKit
/// `NSView`.
///
/// There is deliberately NO "preflight"/"error" outcome and `established`
/// metadata is intentionally not an input: a dead daemon is recovered by
/// `amx attach` itself (zmx `ensureSession`), so an established pane takes the
/// same attach path as a fresh one. The prior preflight that error-latched a
/// missing established session before attaching was the INT-571 bug.
public enum BridgeSurfaceCommandPolicy {
    public static func command(
        bridgeEnabled: Bool,
        attachCommandAvailable: Bool,
        executionPlan: PaneExecutionPlan = .local
    ) -> BridgeSurfaceCommand {
        // Decided before every other input: a remote-owned pane's persistence
        // lives on the far host, so neither the local amx daemon
        // (`attachCommandAvailable`) nor the command bridge (`bridgeEnabled`)
        // has anything to contribute, and neither can make it unreachable.
        if case .ssh(let execution) = executionPlan, execution.persistenceOwner == .remoteZmx {
            return .remoteOwnedAttach
        }
        if bridgeEnabled, attachCommandAvailable { return .bridgeAttach }
        // A remote execution plan wins regardless of `bridgeEnabled`: a pane
        // with no usable attach command (bridge off, or `amx` missing) must
        // error, never silently spawn a local shell that looks like the host.
        let context = ExecutionContext(plan: executionPlan)
        if !context.capability(.launchLocalShellFallback).isAllowed {
            return .remoteUnavailable
        }
        return .localShell
    }
}
