import Testing

@testable import AwesoMuxCore

@Suite("HandleCommandFinishedReducer")
struct HandleCommandFinishedReducerTests {
    private let reducer = HandleCommandFinishedReducer()

    // MARK: - clearStaleError contract (issue contract #1)

    @Test("exit-0 with .error short-circuits to clearStaleError")
    func exitZeroWithErrorClears() {
        let decision = reducer.decision(
            liveExecutionState: .error,
            exitCode: 0,
            detectorResult: nil
        )
        #expect(decision == .clearStaleError)
    }

    /// The "skip the detector" half of the contract: even if the detector
    /// would have produced a state for this exit code, the reducer must
    /// ignore it when `liveExecutionState == .error` and `exitCode == 0`.
    /// Passing a non-nil `detectorResult` here proves that — if the reducer
    /// started consulting the detector first, this test would fail with
    /// `.applyDetectedState(.done)`.
    @Test("exit-0 with .error ignores a non-nil detector result")
    func exitZeroWithErrorIgnoresDetector() {
        let decision = reducer.decision(
            liveExecutionState: .error,
            exitCode: 0,
            detectorResult: .done
        )
        #expect(decision == .clearStaleError)
    }

    // MARK: - Detector fall-through (issue contracts #2 and #3)

    @Test("exit-0 with non-error and a detector result applies that state")
    func exitZeroNonErrorAppliesDetectorResult() {
        let decision = reducer.decision(
            liveExecutionState: .idle,
            exitCode: 0,
            detectorResult: .done
        )
        #expect(decision == .applyDetectedState(.done))
    }

    @Test("exit-0 done is ignored for hook-capable agent kinds")
    func exitZeroDoneIgnoredForHookCapableKinds() {
        for kind in [AgentKind.claudeCode, .codex, .openCode, .pi, .grok] {
            let decision = reducer.decision(
                liveExecutionState: .thinking,
                exitCode: 0,
                detectorResult: .done,
                liveAgentKind: kind
            )
            #expect(decision == .noop, "expected noop for \(kind)")
        }
    }

    @Test("exit-0 with non-error and nil detector result is .noop")
    func exitZeroNonErrorNilDetectorIsNoop() {
        let decision = reducer.decision(
            liveExecutionState: .idle,
            exitCode: 0,
            detectorResult: nil
        )
        #expect(decision == .noop)
    }

    @Test("exit non-zero with a detector result applies regardless of execution state")
    func nonZeroAppliesDetectorResult() {
        let decision = reducer.decision(
            liveExecutionState: .running,
            exitCode: 1,
            detectorResult: .error
        )
        #expect(decision == .applyDetectedState(.error))
    }

    @Test("exit non-zero from .error liveExecutionState still re-applies via the detector")
    func nonZeroFromErrorReappliesViaDetector() {
        let decision = reducer.decision(
            liveExecutionState: .error,
            exitCode: 1,
            detectorResult: .error
        )
        #expect(decision == .applyDetectedState(.error))
    }

    @Test("nil detector result on non-zero exit falls through to .noop")
    func nilDetectorResultOnNonZeroIsNoop() {
        let decision = reducer.decision(
            liveExecutionState: .idle,
            exitCode: 1,
            detectorResult: nil
        )
        #expect(decision == .noop)
    }

    // MARK: - Parametric AgentExecutionState coverage

    /// Pins the contract that ONLY `.error` short-circuits at exit-0. A future
    /// `AgentExecutionState` case must explicitly opt into the short-circuit if
    /// intended; this test fails loudly otherwise.
    @Test(
        "exit-0 short-circuit fires only for .error",
        arguments: AgentExecutionState.allCases
    )
    func exitZeroShortCircuitOnlyForError(state: AgentExecutionState) {
        let decision = reducer.decision(
            liveExecutionState: state,
            exitCode: 0,
            detectorResult: .done
        )
        if state == .error {
            #expect(decision == .clearStaleError)
        } else {
            #expect(decision == .applyDetectedState(.done))
        }
    }
}
