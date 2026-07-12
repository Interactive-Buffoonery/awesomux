import AwesoMuxCore

enum SurfaceRetainSet {
    static func paneIDs(
        mainGroups: [SessionGroup],
        auxiliaryPaneIDs: Set<TerminalPane.ID>
    ) -> Set<TerminalPane.ID> {
        var retainedPaneIDs = paneIDs(in: mainGroups)
        retainedPaneIDs.formUnion(auxiliaryPaneIDs)
        return retainedPaneIDs
    }

    static func paneIDs(in groups: [SessionGroup]) -> Set<TerminalPane.ID> {
        Set(
            groups.flatMap { group in
                group.sessions.flatMap(\.layout.paneIDs)
            }
        )
    }
}
