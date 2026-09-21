import AwesoMuxBridgeProtocol
import AwesoMuxCore
import Testing
@testable import awesoMux

@MainActor
@Suite("Daemon recovery metadata synchronization")
struct DaemonRecoveryMetadataSynchronizerTests {
    @Test("writes local panes once and retries failures")
    func cachesSuccessAndRetriesFailure() async throws {
        let id = try #require(TerminalSessionID(rawValue: "sync-test"))
        var attempts = 0
        let synchronizer = DaemonRecoveryMetadataSynchronizer { receivedID, _ in
            #expect(receivedID == id)
            attempts += 1
            return attempts > 1
        }
        let groups = [fixture(id: id)]

        await synchronizer.synchronize(groups: groups)
        await synchronizer.synchronize(groups: groups)
        await synchronizer.synchronize(groups: groups)

        #expect(attempts == 2)
    }

    @Test("skips remote-owned panes and rewrites after invalidation")
    func ownershipAndInvalidation() async throws {
        let localID = try #require(TerminalSessionID(rawValue: "sync-local"))
        let remoteID = try #require(TerminalSessionID(rawValue: "sync-remote"))
        let remote = try #require(RemoteTarget(user: "alice", host: "box"))
        let remoteName = try #require(RemoteSessionName(rawValue: "build"))
        var writes: [TerminalSessionID] = []
        let synchronizer = DaemonRecoveryMetadataSynchronizer { id, _ in
            writes.append(id)
            return true
        }
        let groups = [
            fixture(id: localID),
            fixture(
                id: remoteID,
                executionPlan: .ssh(SSHExecution(target: remote, remoteSessionName: remoteName))),
        ]

        await synchronizer.synchronize(groups: groups)
        await synchronizer.synchronize(groups: groups)
        synchronizer.invalidate()
        await synchronizer.synchronize(groups: groups)

        #expect(writes == [localID, localID])
    }

    private func fixture(
        id: TerminalSessionID,
        executionPlan: PaneExecutionPlan = .local
    ) -> SessionGroup {
        let pane = TerminalPane(
            terminalSessionID: id,
            title: "Pane",
            workingDirectory: "/tmp",
            executionPlan: executionPlan
        )
        let session = TerminalSession(
            title: "Workspace",
            workingDirectory: "/tmp",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        return SessionGroup(name: "Group", sessions: [session])
    }
}
