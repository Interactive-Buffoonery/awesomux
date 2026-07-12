import Foundation

struct TerminalQuitConfirmationReducer: Sendable {
    static func risks(
        from snapshots: [TerminalQuitConfirmationSnapshot]
    ) -> [TerminalPane.ID: Bool] {
        snapshots.reduce(into: [TerminalPane.ID: Bool]()) { risks, snapshot in
            risks[snapshot.paneID, default: false] =
                risks[snapshot.paneID, default: false] || snapshot.needsConfirmation
        }
    }

    /// Last writer wins per pane for the sampled liveness (there is one live
    /// surface per pane; the OR-fold above only applies to the boolean away
    /// signal). Absent panes are not in the map → reset to `.unsampled`.
    static func liveness(
        from snapshots: [TerminalQuitConfirmationSnapshot]
    ) -> [TerminalPane.ID: ForegroundProcessLiveness] {
        snapshots.reduce(into: [TerminalPane.ID: ForegroundProcessLiveness]()) { map, snapshot in
            map[snapshot.paneID] = snapshot.liveness
        }
    }

    /// Returns the IDs of sessions with >=1 pane whose `needsTerminalQuitConfirmation`
    /// or `foregroundProcessLiveness` actually changed, so callers can reclassify
    /// exactly those sessions' quit-risk cache membership (INT-420). This includes
    /// sessions whose panes were absent from the snapshot batch and got reset to
    /// safe defaults — `apply` walks every session, not just the ones sampled.
    /// Deliberately NOT `@discardableResult`: the one caller must reclassify
    /// every changed session or the quit-risk cache silently drifts (INT-420).
    static func apply(
        risksByPaneID: [TerminalPane.ID: Bool],
        livenessByPaneID: [TerminalPane.ID: ForegroundProcessLiveness],
        to groups: inout [SessionGroup]
    ) -> Set<TerminalSession.ID> {
        var changedSessionIDs: Set<TerminalSession.ID> = []
        for groupIndex in groups.indices {
            for sessionIndex in groups[groupIndex].sessions.indices {
                let sessionID = groups[groupIndex].sessions[sessionIndex].id
                groups[groupIndex].sessions[sessionIndex].layout =
                    groups[groupIndex].sessions[sessionIndex].layout.mappingPanes { pane in
                        let risk = risksByPaneID[pane.id] ?? false
                        let liveness = livenessByPaneID[pane.id] ?? .unsampled
                        guard pane.needsTerminalQuitConfirmation != risk
                            || pane.foregroundProcessLiveness != liveness else {
                            return pane
                        }
                        changedSessionIDs.insert(sessionID)
                        var pane = pane
                        pane.needsTerminalQuitConfirmation = risk
                        pane.foregroundProcessLiveness = liveness
                        return pane
                    }
            }
        }
        return changedSessionIDs
    }
}
