import Foundation

public struct QuitRiskInputs: Sendable, Hashable {
    public var agentKind: AgentKind
    public var agentExecutionState: AgentExecutionState
    public var lastAgentStateChangeAt: Date
    /// The OSC-133 prompt-marker signal (`!cursorIsAtPrompt`). A corroborating
    /// risk signal, not the sole one — see INT-217 / the PR #142 lesson.
    public var awayFromPrompt: Bool
    /// Whether this pane has emitted at least one trustworthy prompt marker.
    /// Before that, `awayFromPrompt` is also Ghostty's startup default and
    /// cannot prove that work is running.
    public var promptObserved: Bool
    public var liveness: ForegroundProcessLiveness

    public init(
        agentKind: AgentKind,
        agentExecutionState: AgentExecutionState,
        lastAgentStateChangeAt: Date,
        awayFromPrompt: Bool,
        promptObserved: Bool = true,
        liveness: ForegroundProcessLiveness
    ) {
        self.agentKind = agentKind
        self.agentExecutionState = agentExecutionState
        self.lastAgentStateChangeAt = lastAgentStateChangeAt
        self.awayFromPrompt = awayFromPrompt
        self.promptObserved = promptObserved
        self.liveness = liveness
    }
}

public enum QuitRiskReason: Sendable, Hashable {
    case daemonBacked, processExited, shellAtPrompt, noLiveProcess          // safe
    case liveForegroundProcess, backgroundJob, liveAgentProcess             // risk
    case activeAgentExecution, terminalAwayFromPrompt, indeterminate        // risk
}

public struct QuitRiskDecision: Sendable, Hashable {
    public let isRisk: Bool
    public let reason: QuitRiskReason
    public init(isRisk: Bool, reason: QuitRiskReason) {
        self.isRisk = isRisk
        self.reason = reason
    }
    static func safe(_ reason: QuitRiskReason) -> QuitRiskDecision { .init(isRisk: false, reason: reason) }
    static func risk(_ reason: QuitRiskReason) -> QuitRiskDecision { .init(isRisk: true, reason: reason) }
}

/// Pure quit-risk decision (INT-217). Process liveness is the primary signal;
/// OSC-133 away-from-prompt corroborates; agent-execution freshness is the
/// fallback when no live foreground is sampled. Testable without SwiftUI.
public enum QuitRiskPolicy {
    public static func decision(_ inputs: QuitRiskInputs, at now: Date) -> QuitRiskDecision {
        // Authoritative-safe: bridged work survives quit; an exited child is gone.
        switch inputs.liveness {
        case .bridged, .bridgedBusy: return .safe(.daemonBacked)
        case .exited: return .safe(.processExited)
        default: break
        }

        // OSC-133 corroboration: away-from-prompt is a risk (overridden only by
        // the authoritative-safe cases above).
        if inputs.promptObserved && inputs.awayFromPrompt {
            return .risk(.terminalAwayFromPrompt)
        }

        switch inputs.liveness {
        case .busyShell:
            return .risk(.backgroundJob)
        case .liveCommand:
            return .risk(inputs.agentKind == .shell ? .liveForegroundProcess : .liveAgentProcess)
        case .indeterminate:
            return .risk(.indeterminate)
        case .idleShell, .unsampled:
            // No live foreground process. An agent mid-turn whose output hasn't
            // settled is still a risk (the detector can lead the process tree).
            if isFreshAgentExecution(inputs, at: now) {
                return .risk(.activeAgentExecution)
            }
            return .safe(inputs.liveness == .idleShell ? .shellAtPrompt : .noLiveProcess)
        case .bridged, .bridgedBusy:
            return .safe(.daemonBacked)    // handled in the first switch; correct if reached
        case .exited:
            return .safe(.processExited)   // handled in the first switch; correct if reached
        }
    }

    /// Close/destroy-scoped variant. A bridged pane is authoritatively safe for
    /// APP QUIT (the daemon keeps the session for reattach), but a close
    /// destroys the session — and the caller kills the daemon session with it —
    /// so daemon-backed is not safe here. Bridged panes fall back to the
    /// OSC-133 and agent-freshness signals the quit path would have skipped.
    public static func closeDecision(_ inputs: QuitRiskInputs, at now: Date) -> QuitRiskDecision {
        guard inputs.liveness == .bridged || inputs.liveness == .bridgedBusy else {
            return decision(inputs, at: now)
        }
        if inputs.liveness == .bridgedBusy {
            return .risk(inputs.agentKind == .shell ? .liveForegroundProcess : .liveAgentProcess)
        }
        if inputs.promptObserved && inputs.awayFromPrompt {
            return .risk(.terminalAwayFromPrompt)
        }
        if isFreshAgentExecution(inputs, at: now) {
            return .risk(.activeAgentExecution)
        }
        if !inputs.promptObserved {
            return .risk(.indeterminate)
        }
        return .safe(.shellAtPrompt)
    }

    private static func isFreshAgentExecution(_ inputs: QuitRiskInputs, at now: Date) -> Bool {
        guard inputs.agentKind != .shell else { return false }
        switch inputs.agentExecutionState {
        case .running, .thinking, .output:
            return now.timeIntervalSince(inputs.lastAgentStateChangeAt) < TerminalPane.staleAgentActivityThreshold
        case .idle, .waiting, .done, .error:
            return false
        }
    }
}
