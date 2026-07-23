import AwesoMuxBridgeProtocol
public enum PopUpTerminalStoreFactory {
    public static let groupName = "Terminal Companion"
    public static let sessionTitle = "terminal companion"

    @MainActor
    public static func makeStore(
        selectedWorkspace: TerminalSession?,
        fallbackHome: String
    ) -> SessionStore {
        let workingDirectory = selectedWorkspace.flatMap {
            WorkingDirectoryValidator.validatedStartupDirectory($0.workingDirectory)
        } ?? WorkingDirectoryValidator.validatedStartupDirectory(fallbackHome)
            ?? WorkingDirectoryValidator.canonicalHomeDirectory
        let session = TerminalSession(
            title: sessionTitle,
            workingDirectory: workingDirectory,
            agentKind: .shell,
            agentState: AgentKind.shell.initialSessionState
        )
        let store = SessionStore(
            groups: [SessionGroup(name: groupName, sessions: [session])],
            selectedSessionID: session.id
        )
        store.compactTerminalKind = .popUpTerminal
        return store
    }
}
