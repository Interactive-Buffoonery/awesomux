import AwesoMuxBridgeProtocol
import Foundation

/// Pure decision for the passive "agent exited, shell survived" detector
/// (INT-552). Providers without a trustworthy quit signal (OpenCode has no
/// quit hook; Codex's `SessionEnd` is deliberately ignored) leave `agentKind`
/// set after the agent process exits back to the prompt, so the tile keeps
/// showing an agent glyph for a non-running agent.
///
/// Lives beside `QuitRiskPolicy` rather than on `ForegroundProcessLiveness`
/// so the process classifier stays free of agent-lifecycle policy
/// (cross-model plan review).
public enum AgentLivenessPolicy {
    /// Whether a pane's sampled foreground liveness proves its tracked agent
    /// has exited, so the agent chrome (glyph, execution state, attention)
    /// must reset to plain shell.
    ///
    /// `.idleShell` and `.bridged` are positive evidence the agent is gone:
    /// both mean a recognized shell was found with zero children, with
    /// `.bridged` deriving that proof from the daemon process tree. Everything
    /// else stays put: live/busy states may still contain the agent, while
    /// exited/indeterminate/unsampled states do not prove the shell outlived it.
    // Two named ceilings. False-retain: a stale glyph over a busy
    // shell (agent exited, unrelated background job remains) — tightening it
    // needs child-process identification. False-reset: a live agent parked
    // behind a foreground interactive subshell idling at its own prompt
    // (shell-escape/REPL shell-out) reads .idleShell and would reset — and
    // the reducer's post-exit latch then suppresses the live agent's later
    // events until its next sessionStart. Unreachable for Claude Code /
    // Codex / OpenCode (they stay the foreground process between turns,
    // .liveCommand); if a future shell-REPL agent lands, upgrade to
    // hysteresis (N consecutive idle samples) or a foreground-pid ==
    // pane-root-shell-pid check before resetting.
    public static func shouldResetAgentChrome(
        agentKind: AgentKind,
        liveness: ForegroundProcessLiveness
    ) -> Bool {
        agentKind != .shell && (liveness == .idleShell || liveness == .bridged)
    }

    /// Remote helper samples: only a proven idle remote shell may drop agent
    /// chrome. `liveCommand` on the far host may be the agent itself; local
    /// `ssh` must not be treated as that proof.
    public static func shouldResetAgentChrome(
        agentKind: AgentKind,
        remoteLiveness: RemoteForegroundLiveness
    ) -> Bool {
        agentKind != .shell && remoteLiveness == .idleShell
    }

    /// First observation of the local SSH client becoming foreground. This is
    /// the aggressive SSH-entry wipe: leftover Claude/Codex chrome must not
    /// ride into the remote session. It is an edge trigger (`justObserved`),
    /// not "comm is ssh", so a managed pane whose local process is always ssh
    /// is not continuously reset, and a still-foreground agent that merely
    /// printed "ssh" is not wiped.
    public static func shouldResetAgentChromeOnSSHForegroundObservation(
        agentKind: AgentKind,
        justObservedSSHClient: Bool
    ) -> Bool {
        agentKind != .shell && justObservedSSHClient
    }
}
