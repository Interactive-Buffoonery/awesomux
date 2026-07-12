enum QuitTerminationPolicy {
    enum Decision: Equatable {
        case terminateNow
        case presentUserQuitRiskAlert
        case presentSystemQuitRiskWarning
    }

    static func decision(
        isSystemInitiatedQuit: Bool,
        hasRiskySessions: Bool
    ) -> Decision {
        guard hasRiskySessions else {
            return .terminateNow
        }
        return isSystemInitiatedQuit
            ? .presentSystemQuitRiskWarning
            : .presentUserQuitRiskAlert
    }
}
