import AwesoMuxCore

enum SSHWorkspaceGroupTargeting {
    static func resolve(
        groups: [SessionGroup],
        selectedSessionID: TerminalSession.ID?,
        defaultGroupName: String
    ) -> SessionGroup? {
        groups.first(where: { group in
            group.sessions.contains { $0.id == selectedSessionID }
        })
            ?? groups.first(where: {
                SessionStore.sanitizedGroupName($0.name).caseInsensitiveCompare(
                    SessionStore.sanitizedGroupName(defaultGroupName)
                ) == .orderedSame
            })
            ?? groups.first
    }
}
