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

    @Test("unestablished panes write only after their attach establishes the backend")
    func waitsForEstablishedBackend() async throws {
        let id = try #require(TerminalSessionID(rawValue: "sync-startup"))
        var writes = 0
        let synchronizer = DaemonRecoveryMetadataSynchronizer { _, _ in
            writes += 1
            return true
        }
        let pending = fixture(id: id, metadata: .empty)
        await synchronizer.synchronize(groups: [pending])
        await synchronizer.synchronize(groups: [pending])
        #expect(writes == 0)

        await synchronizer.synchronize(groups: [fixture(id: id)])
        #expect(writes == 1)
    }

    private func fixture(
        id: TerminalSessionID,
        metadata: TerminalBackendMetadata = AmxBackend.establishedSessionMetadata,
        executionPlan: PaneExecutionPlan = .local
    ) -> SessionGroup {
        let pane = TerminalPane(
            terminalSessionID: id,
            terminalBackendMetadata: metadata,
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
