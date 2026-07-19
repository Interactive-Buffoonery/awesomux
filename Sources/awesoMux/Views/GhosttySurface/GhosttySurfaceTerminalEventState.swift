import AppKit
import AwesoMuxCore

@MainActor
final class GhosttySurfaceTerminalEventState {
    let agentOutputDetector = AgentOutputDetector()
    let handleCommandFinishedReducer = HandleCommandFinishedReducer()
    let visibleTextAgentStateReducer = VisibleTextAgentStateReducer()
    var lastAgentDetectionSample: TimeInterval = 0
    var lastDetectedVisibleText = ""
    /// Visible text as of the last `.valueChanged` accessibility post, so the
    /// sampler only announces once per distinct change instead of once per
    /// sample tick. See `scheduleAccessibilityValueChangeAnnouncement()`.
    var lastAccessibilityReportedVisibleText: String?
    var hasObservedAgentActivity = false
    var lastRuntimeEventAppliedAt: TimeInterval?
    var lastRuntimeAttentionEventAppliedAt: TimeInterval?
    /// The foreground-process incarnation (pid + start time) observed at the
    /// moment a genuine provider hook last confirmed `.waiting` — stamped only
    /// by `applyAgentRuntimeEvent`'s trusted hook path, never by the
    /// process-recognition (`detectAgentExitedToShell`) or visible-text
    /// detector paths that also write `.waiting`. `AgentPromptGate.verdict`
    /// requires this to match the CURRENTLY observed foreground incarnation
    /// before trusting a nudge target — closes the same-provider-relaunch
    /// window where a fresh process gets recognized/scraped into `.waiting`
    /// before its own first real hook ever fires (INT-569 follow-up).
    var verifiedWaitingForegroundIncarnation: AgentForegroundIncarnation?

    /// Auto-clears a `progressReport` that never receives its OSC 9;4
    /// `remove` state — e.g. the emitting process is killed or crashes
    /// mid-report. Re-armed on every visible progress write, invalidated on
    /// `.remove` or teardown. Mirrors Ghostty's `progressReport` `didSet`
    /// timer (`SurfaceView_AppKit.swift:23-33`), which this port didn't
    /// originally carry over. See `updateProgressReport`.
    var progressReportExpiryWorkItem: DispatchWorkItem?

    /// Backs the trailing-edge write throttle in `updateProgressReport` —
    /// see `ProgressReportWriteThrottle` for the decision logic and
    /// `progressReportStoreWriteMinInterval` for the window.
    var progressReportThrottleWorkItem: DispatchWorkItem?
    var lastProgressReportStoreWriteAt: TimeInterval?

    /// Debounces the `.valueChanged` VoiceOver notification posted when the
    /// passive visible-state sampler detects new terminal output. Same
    /// cancel-then-reschedule `DispatchWorkItem` pattern as
    /// `accessibilitySelectionChangeWorkItem` on the view, for the same reason:
    /// a burst of PTY output (a command's stdout, an agent streaming a
    /// response) should collapse to one announcement once it settles, not
    /// one per sample tick.
    var accessibilityValueChangeWorkItem: DispatchWorkItem?
}
