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
            // groupLookupKey, not sanitizedGroupName: routing everywhere else
            // diverts confusable/mixed-script names to the canonical default
            // (INT-485), and this resolver must agree with it.
            ?? groups.first(where: {
                SessionStore.groupLookupKey($0.name).caseInsensitiveCompare(
                    SessionStore.groupLookupKey(defaultGroupName)
                ) == .orderedSame
            })
            ?? groups.first
    }
}
