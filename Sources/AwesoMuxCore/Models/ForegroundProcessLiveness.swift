/// A pane's sampled foreground-process state, the primary quit-risk liveness
/// signal (INT-217). Runtime-only; produced by the app layer from libghostty's
/// `foreground_pid` + a libproc child check, classified here so the truth table
/// is pure and unit-tested.
public enum ForegroundProcessLiveness: Sendable, Hashable {
    /// No surface sampled yet (e.g. an un-mounted pane). Treated as no live
    /// local process — the safe default, matching the lazy-mount invariant the
    /// quit-confirmation sync already relies on.
    case unsampled
    /// Daemon-backed (command-bridge): work survives app quit. Set by the
    /// sampler when the pane is attached to an `amx` daemon.
    case bridged
    /// Daemon-backed, with live work under the daemon shell. App quit remains
    /// safe because the daemon survives; destroying the pane requires warning.
    case bridgedBusy
    /// libghostty reports the surface's child has exited.
    case exited
    /// Foreground is a recognized login shell with no children — idle at prompt.
    case idleShell
    /// Foreground is a recognized shell WITH children — a background job is
    /// running (`npm run dev &`); quit would SIGHUP it.
    case busyShell
    /// Foreground is a live non-shell process — a foreground command or a live
    /// agent process.
    case liveCommand
    /// Surface present but the foreground could not be resolved (pid 0, or a
    /// shell whose child count is unknown). Conservatively a risk.
    case indeterminate

    /// Build the case from raw facts. `foregroundHasChildren` is only meaningful
    /// when the foreground is a shell; `nil` there means "couldn't determine" →
    /// indeterminate (never silently idle).
    public static func classify(
        processExited: Bool,
        foregroundComm: String?,
        foregroundHasChildren: Bool?
    ) -> ForegroundProcessLiveness {
        if processExited {
            return .exited
        }
        guard let comm = foregroundComm else {
            return .indeterminate
        }
        guard ShellRecognition.isRecognizedShell(comm) else {
            return .liveCommand
        }
        switch foregroundHasChildren {
        case .some(true): return .busyShell
        case .some(false): return .idleShell
        case .none: return .indeterminate
        }
    }

    public static func classifyBridged(
        rootComm: String?,
        rootHasChildren: Bool?
    ) -> ForegroundProcessLiveness {
        guard let rootComm else { return .bridged }
        guard ShellRecognition.isRecognizedShell(rootComm) else { return .bridgedBusy }
        return rootHasChildren == true ? .bridgedBusy : .bridged
    }
}
