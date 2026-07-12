import AwesoMuxCore
import DesignSystem
import GhosttyKit
import Testing
@testable import awesoMux

@Suite("SurfaceProgressReport")
@MainActor
struct SurfaceProgressReportTests {
    @Test("maps Ghostty progress enum order")
    func mapsGhosttyProgressEnumOrder() {
        #expect(reportState(GHOSTTY_PROGRESS_STATE_REMOVE) == .remove)
        #expect(reportState(GHOSTTY_PROGRESS_STATE_SET) == .set)
        #expect(reportState(GHOSTTY_PROGRESS_STATE_ERROR) == .error)
        #expect(reportState(GHOSTTY_PROGRESS_STATE_INDETERMINATE) == .indeterminate)
        #expect(reportState(GHOSTTY_PROGRESS_STATE_PAUSE) == .pause)
    }

    @Test("maps missing and bounded progress values")
    func mapsMissingAndBoundedProgressValues() {
        #expect(SurfaceProgressReport(
            state: GHOSTTY_PROGRESS_STATE_SET,
            progress: -1
        ).terminalProgressReport.progress == nil)
        #expect(SurfaceProgressReport(
            state: GHOSTTY_PROGRESS_STATE_SET,
            progress: 50
        ).terminalProgressReport.progress == 50)
        #expect(SurfaceProgressReport(
            state: GHOSTTY_PROGRESS_STATE_SET,
            progress: 127
        ).terminalProgressReport.progress == 100)
        #expect(SurfaceProgressReport(
            state: GHOSTTY_PROGRESS_STATE_INDETERMINATE,
            progress: 50
        ).terminalProgressReport.progress == nil)
    }

    @Test("progress bar exposes accessibility label and value")
    func progressBarExposesAccessibilityLabelAndValue() {
        let set = SurfaceProgressBar(report: TerminalProgressReport(state: .set, progress: 50), accent: .peach)
        #expect(set.accessibilityLabelText == "Terminal progress")
        #expect(set.accessibilityValueText == "50 percent complete")

        let error = SurfaceProgressBar(report: TerminalProgressReport(state: .error), accent: .peach)
        #expect(error.accessibilityLabelText == "Terminal progress - Error")
        #expect(error.accessibilityValueText == "Operation failed")

        let indeterminate = SurfaceProgressBar(
            report: TerminalProgressReport(state: .indeterminate),
            accent: .peach
        )
        #expect(indeterminate.accessibilityLabelText == "Terminal progress - In progress")
        #expect(indeterminate.accessibilityValueText == "Operation in progress")
    }

    @Test("pause without progress renders as complete")
    func pauseWithoutProgressRendersAsComplete() {
        let pause = SurfaceProgressBar(report: TerminalProgressReport(state: .pause), accent: .peach)

        #expect(pause.renderedProgress == 100)
        #expect(pause.accessibilityValueText == "100 percent complete")
    }

    @Test("error WITHOUT a percentage does not double-stack the background track (INT-587 review)")
    func errorWithoutPercentageSkipsDeterminateTrack() {
        // No `progress` on `.error` falls through to `BouncingProgressBar`,
        // which draws its OWN 0.3-alpha background. `showsDeterminateTrack`
        // must be false here or the two layers stack, rendering visibly
        // darker than every other state's single layer.
        let errorNoPercent = SurfaceProgressBar(report: TerminalProgressReport(state: .error), accent: .peach)
        #expect(errorNoPercent.renderedProgress == nil)
        #expect(!errorNoPercent.showsDeterminateTrack)
    }

    @Test("error WITH a percentage still shows the determinate track")
    func errorWithPercentageShowsDeterminateTrack() {
        let errorWithPercent = SurfaceProgressBar(
            report: TerminalProgressReport(state: .error, progress: 40),
            accent: .peach
        )
        #expect(errorWithPercent.showsDeterminateTrack)
    }

    @Test("pause always shows the determinate track (renderedProgress defaults to 100)")
    func pauseShowsDeterminateTrack() {
        let pause = SurfaceProgressBar(report: TerminalProgressReport(state: .pause), accent: .peach)
        #expect(pause.showsDeterminateTrack)
    }

    @Test("indeterminate never shows the determinate track")
    func indeterminateSkipsDeterminateTrack() {
        let indeterminate = SurfaceProgressBar(report: TerminalProgressReport(state: .indeterminate), accent: .peach)
        #expect(!indeterminate.showsDeterminateTrack)
    }

    @Test(".remove is handled defensively even though it's structurally unreachable (INT-587 review)")
    func removeStateAccessibilityTextIsHandled() {
        // `.remove` never actually reaches this view (see the doc comment on
        // `accessibilityLabelText`), but the switch still has to handle it
        // for exhaustiveness — pin down that it doesn't crash or return
        // something nonsensical.
        let removed = SurfaceProgressBar(report: TerminalProgressReport(state: .remove), accent: .peach)
        #expect(removed.accessibilityLabelText == "Terminal progress")
        #expect(removed.accessibilityValueText == "Indeterminate progress")
    }

    @Test("accent participates in == so an accent flip repaints through .equatable()")
    func accentParticipatesInEquality() {
        // Regression guard for the stale-accent bug (PR #428 smoke): the bar
        // sits behind .equatable(), and @Environment invalidation proved
        // unreliable across that gate. The accent must ride the compared
        // value — if == ever stops covering it, an accent change with an
        // unchanged report leaves the bar painted in the old accent.
        let report = TerminalProgressReport(state: .set, progress: 50)
        #expect(
            SurfaceProgressBar(report: report, accent: .peach)
                != SurfaceProgressBar(report: report, accent: .green)
        )
        #expect(
            SurfaceProgressBar(report: report, accent: .peach)
                == SurfaceProgressBar(report: report, accent: .peach)
        )
    }

    private func reportState(
        _ state: ghostty_action_progress_report_state_e
    ) -> TerminalProgressReport.State {
        SurfaceProgressReport(state: state, progress: -1).terminalProgressReport.state
    }
}
