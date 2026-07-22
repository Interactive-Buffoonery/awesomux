import AwesoMuxBridgeProtocol
import Foundation

public enum HandleCommandFinishedDecision: Equatable, Sendable {
    case clearStaleError
    case applyDetectedState(AgentState)
    case noop
}

/// Pure decision layer for the shell-command-finished hook:
///
/// - exit-0 with `liveExecutionState == .error` → `.clearStaleError`
///   (detector result ignored — the stale-error clear contract owns this case
///   unconditionally).
/// - exit-0 `.done` for a hook-capable agent kind → `.noop` (defense in depth
///   against tool shell exits painting Done while the agent is still live).
/// - exit-0 with `liveExecutionState != .error` → detector result decides.
/// - exit non-zero → detector result decides regardless of
///   `liveExecutionState`.
///
/// `detectorResult` is the consumer's pre-computed decision from
/// `AgentOutputDetector.stateForCommandFinished(exitCode:agentWasActive:liveAgentKind:)`.
/// Modeling the domain input directly (rather than holding a detector
/// instance) keeps the reducer pure and makes the "skip detector on stale
/// error" contract directly assertable.
public struct HandleCommandFinishedReducer: Sendable {
    public init() {}

    public func decision(
        liveExecutionState: AgentExecutionState,
        exitCode: Int16,
        detectorResult: AgentState?,
        liveAgentKind: AgentKind = .shell
    ) -> HandleCommandFinishedDecision {
        if exitCode == 0, liveExecutionState == .error {
            return .clearStaleError
        }
        guard let detectorResult else {
            return .noop
        }
        // Belt-and-suspenders with `stateForCommandFinished`: even if a caller
        // still passes `.done` for a hook-capable pane, do not apply it.
        if detectorResult == .done, liveAgentKind.usesReliableHooks {
            return .noop
        }
        return .applyDetectedState(detectorResult)
    }
}
