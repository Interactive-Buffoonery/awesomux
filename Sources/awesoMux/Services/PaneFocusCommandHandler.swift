import AwesoMuxCore

@MainActor
struct PaneFocusCommandHandler {
    let sessionStore: SessionStore
    let requestTerminalFocus: (TerminalSession.ID, TerminalPane.ID) -> Void
    let clearTerminalFocus: (TerminalSession.ID, TerminalPane.ID) -> Void
    let announcePaneFocused: (Int) -> Void

    static func canRequestTerminalFocus(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        sessionStore: SessionStore
    ) -> Bool {
        guard sessionStore.selectedSessionID == sessionID,
            let session = sessionStore.session(id: sessionID),
            session.activePaneID == paneID,
            let pane = session.layout.pane(id: paneID)
        else {
            return false
        }
        return pane.remoteReconnect == nil
    }

    static func canClearTerminalFocus(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        sessionStore: SessionStore
    ) -> Bool {
        guard sessionStore.selectedSessionID == sessionID,
            let session = sessionStore.session(id: sessionID),
            session.activePaneID == paneID,
            let pane = session.layout.pane(id: paneID)
        else {
            return false
        }
        return pane.remoteReconnect != nil
    }

    func focusPane(_ direction: PaneFocusDirection) {
        guard let session = sessionStore.selectedSession,
            session.layout.paneIDs.count > 1
        else {
            return
        }

        sessionStore.focusPane(direction, in: session.id)

        guard sessionStore.selectedSessionID == session.id,
            let updated = sessionStore.session(id: session.id),
            let pane = updated.activePane,
            let index = updated.layout.paneIDs.firstIndex(of: updated.activePaneID)
        else {
            return
        }
        requestTerminalFocusIfAvailable(sessionID: session.id, pane: pane)
        announcePaneFocused(index + 1)
    }

    func focusPane(at index: Int) {
        guard index >= 1,
            let session = sessionStore.selectedSession,
            session.layout.paneIDs.indices.contains(index - 1)
        else {
            return
        }
        let paneID = session.layout.paneIDs[index - 1]
        let didChange = sessionStore.focusPane(at: index, in: session.id)

        guard sessionStore.selectedSessionID == session.id,
            let pane = sessionStore.session(id: session.id)?.layout.pane(id: paneID)
        else {
            return
        }
        requestTerminalFocusIfAvailable(sessionID: session.id, pane: pane)
        if didChange {
            announcePaneFocused(index)
        }
    }

    private func requestTerminalFocusIfAvailable(
        sessionID: TerminalSession.ID,
        pane: TerminalPane
    ) {
        guard sessionStore.selectedSessionID == sessionID,
            let livePane = sessionStore.session(id: sessionID)?.layout.pane(id: pane.id)
        else {
            return
        }
        guard livePane.remoteReconnect == nil else {
            clearTerminalFocus(sessionID, pane.id)
            return
        }
        requestTerminalFocus(sessionID, pane.id)
    }
}
