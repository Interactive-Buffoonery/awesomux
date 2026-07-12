import AwesoMuxCore
import DesignSystem

extension AgentState {
    /// Maps `AgentState` (domain) to its design-system `AwState` equivalent (presentation).
    ///
    /// The mapping is total and 1:1. If you need to remap (e.g. collapse running into
    /// thinking again), that's a design-system contract change — update this switch and
    /// the `AwState` color/label tokens together so the visual language stays coherent.
    /// Untested directly because this file straddles the AwesoMuxCore/DesignSystem
    /// boundary inside the executable target; see Linear follow-up for extraction
    /// into a testable bridge module.
    var awState: AwState {
        switch self {
        case .idle:
            return .idle
        case .running:
            return .running
        case .waiting:
            return .waiting
        case .thinking:
            return .thinking
        case .output:
            return .output
        case .needsAttention:
            return .needs
        case .done:
            return .done
        case .error:
            return .error
        }
    }
}

extension AwState {
    /// Inverse of `AgentState.awState`. Kept adjacent to the forward mapping so a
    /// new state can't be added to one direction only. The footer chips carry an
    /// `AwState` but the roster panel scrolls to an `AgentDisplayState`, so the
    /// chip-tap needs this to name its scroll target.
    var agentDisplayState: AgentDisplayState {
        switch self {
        case .idle:
            return .idle
        case .running:
            return .running
        case .waiting:
            return .waiting
        case .thinking:
            return .thinking
        case .output:
            return .output
        case .needs:
            return .needsAttention
        case .done:
            return .done
        case .error:
            return .error
        }
    }
}
