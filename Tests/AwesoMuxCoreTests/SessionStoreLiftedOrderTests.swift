import AwesoMuxBridgeProtocol
import Foundation
import Testing

@testable import AwesoMuxCore

/// Arrival order for the Needs Input section: first to ask sits at the top, new
/// arrivals append at the bottom, and nothing already in the section ever moves.
/// Group order would let a new arrival insert ABOVE an existing row and shove it
/// down under the user's pointer — the displacement class this section exists to
/// avoid.
@MainActor
@Suite struct SessionStoreLiftedOrderTests {
    /// A store whose selection sits on an untouched calm anchor, so no test here
    /// arms the selection dwell or captures a sticky by accident.
    private func makeStore(
        groupOne: [TerminalSession],
        groupTwo: [TerminalSession] = []
    ) -> (store: SessionStore, anchor: TerminalSession) {
        let anchor = TerminalSession(title: "anchor", workingDirectory: "~")
        var groups = [SessionGroup(name: "One", sessions: [anchor] + groupOne)]
        if !groupTwo.isEmpty {
            groups.append(SessionGroup(name: "Two", sessions: groupTwo))
        }
        let store = SessionStore(groups: groups)
        store.needsInputSectionEnabled = true
        return (store, anchor)
    }

    /// Raises a permission prompt on a workspace's active pane — the real
    /// producer path, so this exercises the same commit the app does.
    private func askForInput(_ store: SessionStore, _ id: TerminalSession.ID) throws {
        let paneID = try #require(store.session(id: id)?.activePaneID)
        store.updatePermissionPromptAttention(
            sessionID: id,
            paneID: paneID,
            countDelta: 1,
            hasPending: true
        )
    }

    @Test func liftedOrderFollowsArrivalNotGroupOrder() throws {
        let alpha = TerminalSession(title: "alpha", workingDirectory: "~")
        let gamma = TerminalSession(title: "gamma", workingDirectory: "~")
        let (store, _) = makeStore(groupOne: [alpha], groupTwo: [gamma])

        // Reverse of group order: the second group asks first.
        try askForInput(store, gamma.id)
        try askForInput(store, alpha.id)

        #expect(store.liftedSessionIDs == [gamma.id, alpha.id])
    }

    @Test func reAskingDoesNotMoveAWorkspaceAlreadyInTheSection() throws {
        let alpha = TerminalSession(title: "alpha", workingDirectory: "~")
        let beta = TerminalSession(title: "beta", workingDirectory: "~")
        let (store, _) = makeStore(groupOne: [beta], groupTwo: [alpha])

        try askForInput(store, alpha.id)
        try askForInput(store, beta.id)
        #expect(store.liftedSessionIDs == [alpha.id, beta.id])

        // Unread goes 1 → 2 on the workspace that has been waiting longest. It
        // does not get to jump the queue by asking twice.
        try askForInput(store, alpha.id)
        #expect(store.liftedSessionIDs == [alpha.id, beta.id])
    }

    @Test func acknowledgingRemovesOneAndLeavesTheRestInOrder() throws {
        let alpha = TerminalSession(title: "alpha", workingDirectory: "~")
        let beta = TerminalSession(title: "beta", workingDirectory: "~")
        let gamma = TerminalSession(title: "gamma", workingDirectory: "~")
        let (store, _) = makeStore(groupOne: [alpha, beta, gamma])

        try askForInput(store, gamma.id)
        try askForInput(store, alpha.id)
        try askForInput(store, beta.id)
        #expect(store.liftedSessionIDs == [gamma.id, alpha.id, beta.id])

        store.acknowledgeAllPanes(in: alpha.id)
        #expect(store.liftedSessionIDs == [gamma.id, beta.id])
    }

    @Test func aNewArrivalAppendsWithoutShiftingExistingRows() throws {
        let alpha = TerminalSession(title: "alpha", workingDirectory: "~")
        let beta = TerminalSession(title: "beta", workingDirectory: "~")
        let gamma = TerminalSession(title: "gamma", workingDirectory: "~")
        // gamma sorts FIRST in group order, so a group-ordered section would
        // insert it above the two waiting rows and displace both.
        let (store, _) = makeStore(groupOne: [gamma, alpha, beta])

        try askForInput(store, alpha.id)
        try askForInput(store, beta.id)
        #expect(store.liftedSessionIDs.firstIndex(of: alpha.id) == 0)
        #expect(store.liftedSessionIDs.firstIndex(of: beta.id) == 1)

        try askForInput(store, gamma.id)
        #expect(store.liftedSessionIDs.firstIndex(of: alpha.id) == 0)
        #expect(store.liftedSessionIDs.firstIndex(of: beta.id) == 1)
        #expect(store.liftedSessionIDs.firstIndex(of: gamma.id) == 2)
    }

    @Test func pinningALiftedWorkspaceRemovesItFromTheSection() throws {
        let alpha = TerminalSession(title: "alpha", workingDirectory: "~")
        let beta = TerminalSession(title: "beta", workingDirectory: "~")
        let (store, _) = makeStore(groupOne: [alpha, beta])

        try askForInput(store, alpha.id)
        try askForInput(store, beta.id)
        #expect(store.liftedSessionIDs == [alpha.id, beta.id])

        store.togglePin(sessionID: alpha.id)
        #expect(store.liftedSessionIDs == [beta.id])

        // Unpinning re-enters the section as a fresh arrival: it appends.
        store.togglePin(sessionID: alpha.id)
        #expect(store.liftedSessionIDs == [beta.id, alpha.id])
    }

    @Test func closingAWorkspaceDropsItFromTheOrder() throws {
        let alpha = TerminalSession(title: "alpha", workingDirectory: "~")
        let beta = TerminalSession(title: "beta", workingDirectory: "~")
        let (store, _) = makeStore(groupOne: [alpha, beta])

        try askForInput(store, beta.id)
        try askForInput(store, alpha.id)
        #expect(store.liftedSessionIDs == [beta.id, alpha.id])

        store.closeSession(id: beta.id)
        #expect(store.liftedSessionIDs == [alpha.id])
    }

    /// Arrival order is runtime-only. A relaunch rebuilds it in group order,
    /// which is also what a bulk restore must do rather than carrying stale IDs.
    @Test func replaceStateRebuildsTheOrderFromGroupOrder() throws {
        let alpha = TerminalSession(title: "alpha", workingDirectory: "~")
        let beta = TerminalSession(title: "beta", workingDirectory: "~")
        let (store, _) = makeStore(groupOne: [alpha, beta])

        try askForInput(store, beta.id)
        try askForInput(store, alpha.id)
        #expect(store.liftedSessionIDs == [beta.id, alpha.id])

        // Same IDs restored, both needy — the ID-reuse hazard. The pre-restore
        // arrival order must not survive.
        func needy(_ session: TerminalSession) -> TerminalSession {
            var restored = session
            restored.layout = restored.layout.mappingPanes { pane in
                var pane = pane
                pane.attentionReason = .permissionPrompt
                return pane
            }
            return restored
        }
        store.replaceState(
            restoring: SessionSnapshot(
                groups: [SessionGroup(name: "One", sessions: [needy(alpha), needy(beta)])],
                selectedSessionID: alpha.id
            )
        )
        #expect(store.liftedSessionIDs == [alpha.id, beta.id])
    }
}
