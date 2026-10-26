import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("SessionStore — Close Group (INT-206)")
struct SessionStoreCloseGroupTests {

    /// Closing the sole group used to leave an empty shell behind, because
    /// `removeGroup` refused the last group. It now removes it outright.
    ///
    /// The `groups.isEmpty` + `selectedSessionID == nil` pair is asserted
    /// together deliberately: that combination is what drives
    /// `SessionDetailView.emptyStateMode` to `.firstLaunch`, which is the
    /// entire reason this destination is acceptable to land on.
    @Test("closing the sole group removes it, leaving an empty tree")
    func closeSoleGroupLeavesEmptyTree() {
        let first = makeSession("first")
        let second = makeSession("second")
        let sole = SessionGroup(name: "sole", sessions: [first, second])
        let store = SessionStore(groups: [sole], selectedSessionID: first.id)

        #expect(store.closeGroup(id: sole.id))

        #expect(store.groups.isEmpty)
        #expect(store.selectedSessionID == nil)
    }

    @Test("a session that joined after confirmation survives a limited close")
    func limitedCloseSparesUnconfirmedJoiner() {
        let first = makeSession("first")
        let second = makeSession("second")
        let doomed = SessionGroup(name: "doomed", sessions: [first, second])
        let kept = SessionGroup(name: "kept", sessions: [makeSession("survivor")])
        let store = SessionStore(groups: [doomed, kept])
        let confirmedIDs = [first.id, second.id]

        // Simulates a workspace joining the group while the confirm modal
        // is up: it was never part of the confirmed membership.
        _ = store.addSession(title: "joiner", groupName: "doomed")

        let removed = store.closeGroup(id: doomed.id, limitedTo: confirmedIDs)

        #expect(removed == false)
        #expect(store.session(id: first.id) == nil)
        #expect(store.session(id: second.id) == nil)
        let surviving = store.groups.first(where: { $0.id == doomed.id })
        #expect(surviving?.sessions.map(\.title) == ["joiner"])
    }

    @Test("a confirmed session that left the group survives a limited close")
    func limitedCloseSparesConfirmedLeaver() {
        let stays = makeSession("stays")
        let leaves = makeSession("leaves")
        let doomed = SessionGroup(name: "doomed", sessions: [stays, leaves])
        let other = SessionGroup(name: "other", sessions: [makeSession("survivor")])
        let store = SessionStore(groups: [doomed, other])
        let confirmedIDs = [stays.id, leaves.id]

        // Simulates a confirmed workspace being moved out of the group
        // while the confirm modal is up.
        store.moveSession(id: leaves.id, toGroupID: other.id, atIndex: SessionStore.appendIndex)

        let removed = store.closeGroup(id: doomed.id, limitedTo: confirmedIDs)

        #expect(removed == true)
        #expect(store.session(id: stays.id) == nil)
        #expect(store.session(id: leaves.id) != nil)
        let destination = store.groups.first(where: { $0.id == other.id })
        #expect(destination?.sessions.contains(where: { $0.id == leaves.id }) == true)
    }

    // Close dispatch must survive a missing primary window and delayed kills.
    @Test("carrier close plan spares local and moved panes and selects closed or recycled remote panes")
    func carrierClosePlan() throws {
        let target = try #require(RemoteTarget(user: "example", host: "example.com"))
        let execution = try #require(
            SSHExecution(
                target: target, persistenceOwner: .remoteZmx,
                sessionName: RemoteSessionName(rawValue: "work")))
        let remote = TerminalPane(title: "remote", workingDirectory: "~", executionPlan: .ssh(execution))
        let local = TerminalPane(title: "local", workingDirectory: "~", executionPlan: .local)
        func groups(_ panes: [TerminalPane]) -> [SessionGroup] {
            [
                SessionGroup(
                    name: "main",
                    sessions: panes.map {
                        TerminalSession(title: $0.title, workingDirectory: "~", layout: .pane($0))
                    })
            ]
        }
        let previous = DaemonGCPlan.remoteCarrierSessionIDs(in: groups([local, remote]))
        #expect(previous == [remote.terminalSessionID])
        #expect(DaemonGCPlan.closedRemoteCarrierSessionIDs(previous: previous, groups: []) == [remote.terminalSessionID])
        let moved = [SessionGroup(name: "other", sessions: groups([remote])[0].sessions)]
        #expect(DaemonGCPlan.closedRemoteCarrierSessionIDs(previous: previous, groups: moved).isEmpty)
        var recycled = remote
        recycled.terminalSessionID = .generate()
        #expect(DaemonGCPlan.closedRemoteCarrierSessionIDs(previous: previous, groups: groups([recycled])) == [remote.terminalSessionID])
        #expect(DaemonGCPlan.closedRemoteCarrierSessionIDs(previous: previous, groups: groups([local, remote])).isEmpty)
    }

    @Test("store dispatches remote carrier close without a mounted window")
    func carrierCloseDispatchWithoutWindow() throws {
        let target = try #require(RemoteTarget(user: "example", host: "example.com"))
        let execution = try #require(
            SSHExecution(
                target: target, persistenceOwner: .remoteZmx,
                sessionName: RemoteSessionName(rawValue: "work")))
        let pane = TerminalPane(title: "remote", workingDirectory: "~", executionPlan: .ssh(execution))
        let session = TerminalSession(title: "remote", workingDirectory: "~", layout: .pane(pane))
        let local = makeSession("local")
        let group = SessionGroup(name: "main", sessions: [session, local])
        let store = SessionStore(groups: [group])
        var dispatched: [TerminalSessionID] = []
        store.remoteCarrierCloseHandler = { dispatched += $0 }
        #expect(store.closeGroup(id: group.id))
        #expect(dispatched == [pane.terminalSessionID])
        let entry = try #require(store.recentlyClosed.first { $0.sessionID == session.id })
        let reopenedID = try #require(store.reopen(entry))
        let reopened = try #require(store.session(id: reopenedID)?.panes.first)
        #expect(reopened.terminalSessionID != pane.terminalSessionID)
        #expect(reopened.terminalBackendMetadata == .empty)
        #expect(dispatched == [pane.terminalSessionID])
    }

    private func makeSession(
        _ title: String,
        agentState: AgentState = .idle,
        isTitleUserEdited: Bool = false
    ) -> TerminalSession {
        TerminalSession(
            title: title,
            workingDirectory: "~",
            isTitleUserEdited: isTitleUserEdited,
            agentKind: .shell,
            agentState: agentState
        )
    }
}
