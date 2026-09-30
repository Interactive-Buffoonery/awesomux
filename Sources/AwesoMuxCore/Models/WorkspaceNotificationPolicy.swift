import AwesoMuxBridgeProtocol
import Foundation

public struct WorkspaceNotificationPolicy: Sendable {
    public enum FocusContext: Equatable, Sendable {
        case selectedWorkspaceActive
        case otherWorkspaceActive
        case appInactive
    }

    public init() {}

    public func focusContext(
        isSelectedWorkspace: Bool,
        isAppActive: Bool
    ) -> FocusContext {
        if !isAppActive {
            return .appInactive
        }

        return isSelectedWorkspace ? .selectedWorkspaceActive : .otherWorkspaceActive
    }

    public func isAttentionEligible(
        attentionReason: AttentionReason?,
        outputMarksNeedsAttention: Bool = true
    ) -> Bool {
        attentionReason != nil && outputMarksNeedsAttention
    }
}
