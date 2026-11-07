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

    /// Each worktree build is its own Dock app, so windowless dev builds pile up.
    static func terminatesAfterLastWindowClosed(
        profile: AppRuntimeProfile,
        quitWasCancelledWithNoWindowsOpen: Bool
    ) -> Bool {
        guard case .development = profile else { return false }
        return !quitWasCancelledWithNoWindowsOpen
    }
}
