import AwesoMuxBridgeProtocol
import AwesoMuxCore
import AwesoMuxTestSupport
import Testing
@testable import awesoMux

@MainActor
@Suite("Daemon recovery metadata synchronization")
struct DaemonRecoveryMetadataSynchronizerTests {

    @Test("carrier presentation labels preserve the nonrecoverable marker")
    func carrierLabels() async throws {
        let target = try #require(RemoteTarget(user: "example", host: "example.com"))
        let execution = try #require(
            SSHExecution(
                target: target, persistenceOwner: .remoteZmx,
                sessionName: RemoteSessionName(rawValue: "work")))
        let id = TerminalSessionID.generate()
        var written: DaemonRecoveryMetadata?
        let synchronizer = DaemonRecoveryMetadataSynchronizer(writer: { _, metadata in
            written = metadata
            return true
        })
        await synchronizer.synchronize(groups: [
            fixture(id: id, metadata: .amxRemoteCarrier, executionPlan: .ssh(execution))
        ])
        let metadata = try #require(written)
        #expect(metadata.workspaceTitle == "Workspace")
        #expect(metadata.paneTitle == "Pane")
        #expect(DaemonRecoveryMetadata.decode(fields: metadata.encodedLabelAssignments).isRemoteCarrier)
        let row = try #require(
            DaemonStateResolver.resolve(
                .init(
                    live: [LiveDaemon(id: id, pid: 10, createdEpoch: 20, clients: 0, recoveryMetadata: metadata)],
                    idleByID: [:], ownedByLivePane: [], restorable: [], owners: [:], pinned: [],
                    capThresholdSeconds: nil, now: 30)
            ).first)
        #expect(row.label == "Workspace")
        #expect(row.isRemoteCarrier)
        #expect(row.primaryAction == nil)
    }

    @Test("cooldown flushes the latest skipped metadata without another mutation")
    func flushesLatestSkippedUpdate() async throws {
        let id = try #require(TerminalSessionID(rawValue: "sync-deferred"))
        let gate = AsyncGate()
        var now = ContinuousClock.now
        let deadline = now.advanced(by: .seconds(30))
        var titles: [String?] = []
        let synchronizer = DaemonRecoveryMetadataSynchronizer(
            now: { now },
            sleepUntil: { requested in
                #expect(requested == deadline)
                await gate.wait()
            }
        ) { _, metadata in
            titles.append(metadata.workspaceTitle)
            return false
        }
        var group = fixture(id: id)
        await synchronizer.synchronize(groups: [group])
        #expect(await waitUntil { gate.waiterCount == 1 })
        group.sessions[0].title = "Intermediate"
        await synchronizer.synchronize(groups: [group])
        #expect(await waitUntil { gate.waiterCount == 1 })
        group.sessions[0].title = "Latest"
        await synchronizer.synchronize(groups: [group])
        #expect(titles == ["Workspace"])
        now = deadline
        gate.open()
        #expect(await waitUntil { titles.count == 2 })
        #expect(titles == ["Workspace", "Latest"])
        await drainMainQueue()
        #expect(gate.waitCallCount == 1)
        #expect(titles.count == 2)
    }

    @Test("failed writes throttle changing metadata and retry its latest value")
    func throttlesFailuresAcrossChanges() async throws {
        let id = try #require(TerminalSessionID(rawValue: "sync-throttled"))
        var now = ContinuousClock.now
        var titles: [String?] = []
        let synchronizer = DaemonRecoveryMetadataSynchronizer(
            now: { now },
            writer: { _, metadata in
                titles.append(metadata.workspaceTitle)
                return false
            })
        let original = fixture(id: id)
        var changed = original
        changed.sessions[0].title = "Latest"

        await synchronizer.synchronize(groups: [original])
        for _ in 0..<10 {
            await synchronizer.synchronize(groups: [changed])
        }
        await synchronizer.synchronize(groups: [fixture(id: id, metadata: .empty)])
        await synchronizer.synchronize(groups: [changed])
        #expect(titles == ["Workspace"])
        now = now.advanced(by: .seconds(30))
        await synchronizer.synchronize(groups: [changed])
        await synchronizer.synchronize(groups: [changed])
        #expect(titles == ["Workspace", "Latest"])

        synchronizer.invalidate()
        await synchronizer.synchronize(groups: [changed])
        #expect(titles == ["Workspace", "Latest", "Latest"])
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
