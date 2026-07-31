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
}
