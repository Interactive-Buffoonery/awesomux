import Foundation

public struct WorkspaceNotificationPolicy: Sendable {
    public struct Channels: OptionSet, Hashable, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        // Bit ordering is part of the public surface — these rawValues may
        // be persisted (settings export, debug logs) in the future. Add new
        // channels at the end with the next free bit; do not reorder.
        public static let inPaneBanner = Channels(rawValue: 1 << 0)
        public static let sidebarIndicator = Channels(rawValue: 1 << 1)
        public static let tabIndicator = Channels(rawValue: 1 << 2)
        public static let dockBadge = Channels(rawValue: 1 << 3)
        public static let macOSNotification = Channels(rawValue: 1 << 4)
        public static let sound = Channels(rawValue: 1 << 5)

        public static let visibleState: Channels = [
            .inPaneBanner,
            .sidebarIndicator,
            .tabIndicator,
            .dockBadge
        ]

        public static let interruptive: Channels = [
            .macOSNotification,
            .sound
        ]

        public static let all: Channels = visibleState.union(interruptive)
    }

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

    public func channels(
        for state: AgentState,
        focusContext: FocusContext,
        outputMarksNeedsAttention: Bool = true,
        isWorkspaceMuted: Bool = false
    ) -> Channels {
        // `?? .running` is an arbitrary placeholder: the only state with a nil
        // `executionState` is `.needsAttention`, and the executionState
        // dimension is never consulted once `attentionReason` is the sole gate
        // (see the channels(executionState:...) overload). Do not branch policy
        // on this value — it is not a real execution truth.
        channels(
            executionState: state.executionState ?? .running,
            attentionReason: state.attentionReason,
            focusContext: focusContext,
            outputMarksNeedsAttention: outputMarksNeedsAttention,
            isWorkspaceMuted: isWorkspaceMuted
        )
    }

    public func channels(
        executionState: AgentExecutionState,
        attentionReason: AttentionReason?,
        focusContext: FocusContext,
        outputMarksNeedsAttention: Bool = true,
        isWorkspaceMuted: Bool = false
    ) -> Channels {
        // Exhaustive switch — adding a new execution state forces a policy
        // decision rather than silently falling through to no channels.
        switch executionState {
        case .idle, .running, .waiting, .thinking, .output, .done, .error:
            break
        }

        guard attentionReason != nil else {
            return []
        }

        guard outputMarksNeedsAttention else {
            return []
        }

        var channels = Channels.visibleState

        switch focusContext {
        case .selectedWorkspaceActive:
            break
        case .otherWorkspaceActive, .appInactive:
            channels.formUnion(.interruptive)
        }

        // Per-workspace mute (INT-598) gates ONLY the interruptive channels.
        // The workspace keeps its visible state — sidebar dot, tab indicator,
        // dock badge, in-pane banner — so a muted workspace's attention is
        // still discoverable in-app; the user asked not to be interrupted,
        // not to have the state hidden.
        if isWorkspaceMuted {
            channels.subtract(.interruptive)
        }

        return channels
    }
}
