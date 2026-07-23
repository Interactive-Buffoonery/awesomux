import AwesoMuxBridgeProtocol
import AwesoMuxCore
import Foundation

public enum TestData {
    public static func pane(
        id: UUID = UUID(),
        terminalSessionID: TerminalSessionID = .generate(),
        title: String = "Pane",
        workingDirectory: String = "/tmp",
        agentKind: AgentKind = .shell,
        agentExecutionState: AgentExecutionState = .idle,
        attentionReason: AttentionReason? = nil,
        unreadNotificationCount: Int = 0,
        executionPlan: PaneExecutionPlan = .local
    ) -> TerminalPane {
        TerminalPane(
            id: id,
            terminalSessionID: terminalSessionID,
            title: title,
            workingDirectory: workingDirectory,
            agentKind: agentKind,
            agentExecutionState: agentExecutionState,
            attentionReason: attentionReason,
            unreadNotificationCount: unreadNotificationCount,
            executionPlan: executionPlan
        )
    }

    public static func session(
        id: UUID = UUID(),
        title: String = "Workspace",
        workingDirectory: String = "/tmp",
        notificationsMuted: Bool = false,
        layout: TerminalPaneLayout? = nil,
        activePaneID: TerminalPane.ID? = nil
    ) -> TerminalSession {
        let resolvedLayout = layout ?? .pane(pane(workingDirectory: workingDirectory))
        return TerminalSession(
            id: id,
            title: title,
            workingDirectory: workingDirectory,
            notificationsMuted: notificationsMuted,
            layout: resolvedLayout,
            activePaneID: activePaneID
        )
    }

    public static func workspace(
        id: UUID = UUID(),
        name: String = "Group",
        color: WorkspaceGroupColor? = nil,
        remote: RemoteTarget? = nil,
        sessions: [TerminalSession] = [session()]
    ) -> SessionGroup {
        SessionGroup(id: id, name: name, color: color, remote: remote, sessions: sessions)
    }
}
