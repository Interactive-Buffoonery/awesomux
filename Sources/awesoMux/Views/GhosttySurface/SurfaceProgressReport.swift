import AwesoMuxCore
import GhosttyKit

// No `Equatable` conformance: nothing compares two reports directly, they're
// only ever mapped once via `terminalProgressReport` (which IS Equatable).
struct SurfaceProgressReport {
    let state: TerminalProgressReport.State
    let progress: UInt8?

    init(_ report: ghostty_action_progress_report_s) {
        self.init(state: report.state, progress: report.progress)
    }

    init(state: ghostty_action_progress_report_state_e, progress: Int8) {
        self.state = Self.state(from: state)
        self.progress = Self.progress(from: progress, state: self.state)
    }

    var terminalProgressReport: TerminalProgressReport {
        TerminalProgressReport(state: state, progress: progress)
    }

    private static func state(
        from state: ghostty_action_progress_report_state_e
    ) -> TerminalProgressReport.State {
        switch state {
        case GHOSTTY_PROGRESS_STATE_REMOVE:
            return .remove
        case GHOSTTY_PROGRESS_STATE_SET:
            return .set
        case GHOSTTY_PROGRESS_STATE_ERROR:
            return .error
        case GHOSTTY_PROGRESS_STATE_INDETERMINATE:
            return .indeterminate
        case GHOSTTY_PROGRESS_STATE_PAUSE:
            return .pause
        default:
            return .remove
        }
    }

    private static func progress(
        from progress: Int8,
        state: TerminalProgressReport.State
    ) -> UInt8? {
        guard state != .remove, state != .indeterminate, progress >= 0 else {
            return nil
        }

        return UInt8(min(progress, 100))
    }
}
