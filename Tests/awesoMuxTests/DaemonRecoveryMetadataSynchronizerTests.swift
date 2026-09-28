import AwesoMuxBridgeProtocol
import AwesoMuxCore
import AwesoMuxTestSupport
import Testing
@testable import awesoMux

@MainActor
@Suite("Daemon recovery metadata synchronization")
struct DaemonRecoveryMetadataSynchronizerTests {
    @Test("staggered failed flushes do not keep retrying each other")
    func consumesDeferredUpdates() async throws {
        let firstID = try #require(TerminalSessionID(rawValue: "sync-first"))
        let secondID = try #require(TerminalSessionID(rawValue: "sync-second"))
        let start = ContinuousClock.now
        var now = start
        let firstGate = AsyncGate()
        let secondGate = AsyncGate()
        let unexpectedGate = AsyncGate()
        var sleeps = 0
        var writes: [TerminalSessionID] = []
        let synchronizer = DaemonRecoveryMetadataSynchronizer(
            now: { now },
            sleepUntil: { deadline in
                sleeps += 1
                if deadline == start.advanced(by: .seconds(30)) {
                    await firstGate.wait()
                } else if deadline == start.advanced(by: .seconds(45)) {
                    await secondGate.wait()
                } else {
                    await unexpectedGate.wait()
                }
            }
        ) { id, _ in
            writes.append(id)
            if writes.count == 2 { now = start.advanced(by: .seconds(15)) }
            return false
        }
        defer {
            synchronizer.invalidate()
            firstGate.open()
            secondGate.open()
            unexpectedGate.open()
        }
        let groups = [fixture(id: firstID), fixture(id: secondID)]
        await synchronizer.synchronize(groups: groups)
        await synchronizer.synchronize(groups: groups)
        #expect(await waitUntil { firstGate.waiterCount == 1 })
        now = start.advanced(by: .seconds(30))
        firstGate.open()
        #expect(await waitUntil { secondGate.waiterCount == 1 })
        now = start.advanced(by: .seconds(45))
        secondGate.open()
        #expect(await waitUntil { writes.count == 4 })
        await drainMainQueue()
        #expect(writes == [firstID, secondID, firstID, secondID])
        #expect(sleeps == 2)
    }

    @Test("an initial failure retries once without another mutation")
    func retriesInitialFailureOnce() async throws {
        let id = try #require(TerminalSessionID(rawValue: "sync-initial-retry"))
        let gate = AsyncGate()
        var now = ContinuousClock.now
        let deadline = now.advanced(by: .seconds(30))
        var attempts = 0
        let synchronizer = DaemonRecoveryMetadataSynchronizer(
            now: { now },
            sleepUntil: { requested in
                #expect(requested == deadline)
                await gate.wait()
            }
        ) { _, _ in
            attempts += 1
            return false
        }
        defer {
            synchronizer.invalidate()
            gate.open()
        }

        await synchronizer.synchronize(groups: [fixture(id: id)])
        #expect(await waitUntil { gate.waiterCount == 1 })
        now = deadline
        gate.open()
        #expect(await waitUntil { attempts == 2 })
        await drainMainQueue()
        #expect(gate.waitCallCount == 1)
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

    @Test(
        "cancelled deferred writes cannot run after invalidation, removal, or release",
        arguments: ["invalidate", "remove", "release"])
    func cancelsDeferredWrite(action: String) async throws {
        let id = try #require(TerminalSessionID(rawValue: "sync-cancelled"))
        let gate = AsyncGate()
        var attempts = 0
        var synchronizer: DaemonRecoveryMetadataSynchronizer? = DaemonRecoveryMetadataSynchronizer(
            sleepUntil: { _ in await gate.wait() }
        ) { _, _ in
            attempts += 1
            return false
        }
        let groups = [fixture(id: id)]
        await synchronizer?.synchronize(groups: groups)
        await synchronizer?.synchronize(groups: groups)
        #expect(await waitUntil { gate.waiterCount == 1 })
        weak let owner = synchronizer
        switch action {
        case "invalidate": synchronizer?.invalidate()
        case "remove": await synchronizer?.synchronize(groups: [])
        default:
            synchronizer = nil
            #expect(owner == nil)
        }
        gate.open()
        await drainMainQueue()
        #expect(attempts == 1)
    }

    @Test("writes local panes once and retries failures")
    func cachesSuccessAndRetriesFailure() async throws {
        let id = try #require(TerminalSessionID(rawValue: "sync-test"))
        var attempts = 0
        var now = ContinuousClock.now
        let synchronizer = DaemonRecoveryMetadataSynchronizer(
            now: { now },
            writer: { receivedID, _ in
                #expect(receivedID == id)
                attempts += 1
                return attempts > 1
            })
        let groups = [fixture(id: id)]

        await synchronizer.synchronize(groups: groups)
        await synchronizer.synchronize(groups: groups)
        #expect(attempts == 1)
        now = now.advanced(by: .seconds(30))
        await synchronizer.synchronize(groups: groups)
        await synchronizer.synchronize(groups: groups)

        #expect(attempts == 2)
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

    @Test("skips remote-owned panes and rewrites after invalidation")
    func ownershipAndInvalidation() async throws {
        let localID = try #require(TerminalSessionID(rawValue: "sync-local"))
        let remoteID = try #require(TerminalSessionID(rawValue: "sync-remote"))
        let remote = try #require(RemoteTarget(user: "alice", host: "box"))
        let remoteName = try #require(RemoteSessionName(rawValue: "build"))
        var writes: [TerminalSessionID] = []
        let synchronizer = DaemonRecoveryMetadataSynchronizer(writer: { id, _ in
            writes.append(id)
            return true
        })
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
        let synchronizer = DaemonRecoveryMetadataSynchronizer(writer: { _, _ in
            writes += 1
            return true
        })
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
