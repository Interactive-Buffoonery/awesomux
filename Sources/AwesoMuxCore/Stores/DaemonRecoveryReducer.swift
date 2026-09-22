import AwesoMuxBridgeProtocol
import Foundation

public struct DaemonRecoveryRequest: Sendable {
    public let id: TerminalSessionID
    public let metadata: DaemonRecoveryMetadata
    public let cwd: String?

    public init(id: TerminalSessionID, metadata: DaemonRecoveryMetadata, cwd: String?) {
        self.id = id
        self.metadata = metadata
        self.cwd = cwd
    }
}

public enum DaemonRecoveryReducer {
    public static func recover(
        _ request: DaemonRecoveryRequest,
        into groups: inout [SessionGroup]
    ) -> TerminalSession.ID? {
        guard
            !groups.contains(where: { group in
                group.sessions.contains { session in
                    session.panes.contains { $0.terminalSessionID == request.id }
                }
            })
        else { return nil }

        let directory: String
        if let remote = request.metadata.groupRemote {
            directory = request.cwd ?? "~"
            return insert(request, directory: directory, plan: .ssh(SSHExecution(target: remote)), into: &groups)
        }
        directory = request.cwd.flatMap { WorkingDirectoryValidator.validatedReportedDirectory($0) } ?? "~"
        return insert(request, directory: directory, plan: .local, into: &groups)
    }

    private static func insert(
        _ request: DaemonRecoveryRequest,
        directory: String,
        plan: PaneExecutionPlan,
        into groups: inout [SessionGroup]
    ) -> TerminalSession.ID {
        let pane = TerminalPane(
            terminalSessionID: request.id,
            terminalBackendMetadata: TerminalBackendMetadata(rawValue: "amx:v1:existing-only"),
            title: request.metadata.paneTitle ?? request.metadata.workspaceTitle ?? request.id.rawValue,
            workingDirectory: directory,
            agentKind: request.metadata.agentKind ?? .shell,
            executionPlan: plan
        )
        let directoryName = URL(fileURLWithPath: directory).lastPathComponent
        let title =
            request.metadata.workspaceTitle
            ?? (directoryName.isEmpty ? request.id.rawValue : directoryName)
        let session = TerminalSession(
            title: title,
            workingDirectory: directory,
            agentKind: request.metadata.agentKind,
            layout: .pane(pane),
            activePaneID: pane.id
        )
        if let groupID = request.metadata.groupID,
            let index = groups.firstIndex(where: { $0.id == groupID })
        {
            groups[index].sessions.append(session)
        } else {
            let baseName = request.metadata.groupName ?? "Recovered Sessions"
            let name =
                WorkspaceTreeReducer.containsGroup(
                    in: groups, named: SessionStoreText.groupLookupKey(baseName))
                ? SessionRestoreReducer.disambiguatedName(for: baseName, reserved: groups.map(\.name))
                : baseName
            groups.append(
                SessionGroup(
                    id: request.metadata.groupID ?? UUID(),
                    name: name,
                    remote: request.metadata.groupRemote,
                    sessions: [session]
                ))
        }
        return session.id
    }
}
