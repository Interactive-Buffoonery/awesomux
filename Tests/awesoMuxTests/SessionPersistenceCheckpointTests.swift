@testable import AwesoMuxCore
import AwesoMuxTestSupport
import Foundation
import Testing
@testable import awesoMux

extension SessionPersistenceSerializationDomainTests {
    @MainActor
    @Suite("Session persistence checkpoint progress")
    struct SessionPersistenceCheckpointTests {
        @Test("continuous title changes checkpoint structural edits and the final state")
        func continuousChangesMakeProgress() async throws {
            let directory = try TemporaryDirectory(prefix: "session-checkpoints")
            let scheduler = TestScheduler()
            try await SessionPersistence.withTemporarySupportDirectoryAsync(
                directory.url, sleep: { await scheduler.wait(for: $0) }
            ) {
                let store = Self.store()
                let session = try #require(store.groups.first?.sessions.first)
                let paneID = session.activePaneID
                var completions = 0
                store.onDisplayOnlyTitleWrite = { [weak store] in
                    guard let store else { return }
                    SessionPersistence.save(store) { result in
                        #expect(throws: Never.self) { try result.get() }
                        completions += 1
                    }
                }
                defer { store.onDisplayOnlyTitleWrite = nil }

                for window in 1...3 {
                    for update in 1...5 {
                        store.updatePane(sessionID: session.id, paneID: paneID, title: "title-\(window)-\(update)")
                        // Each update arrives while the 500 ms window is still
                        // pending. Scheduling must not restart for these saves.
                        await drainMainQueue(rounds: 1)
                        if update == 3 {
                            _ = store.renameGroup(id: store.groups[0].id, to: "structural-\(window)")
                            store.addSession(title: "added-\(window)", groupName: store.groups[0].name)
                            SessionPersistence.save(store) { _ in completions += 1 }
                        }
                    }
                    #expect(scheduler.sleepCallCount == window)
                    #expect(scheduler.requestedDurations.last == .milliseconds(500))
                    scheduler.advanceOneCycle()
                    #expect(await waitUntilEventually { completions == window })
                    let saved = try Self.read(directory.url)
                    #expect(saved.groups[0].name == "structural-\(window)")
                    #expect(saved.groups[0].sessions.count == window + 1)
                    #expect(saved.groups[0].sessions.last?.title == "added-\(window)")
                    #expect(saved.groups[0].sessions[0].title == "title-\(window)-5")
                }
                // The last window has no following update to trigger its write.
                #expect(completions == 3)
            }
        }

        @Test("restore disable and recovery blocking cancel a scheduled checkpoint", arguments: [false, true])
        func scheduledCheckpointCancellation(recovery: Bool) async throws {
            let directory = try TemporaryDirectory(prefix: "session-checkpoint-cancel")
            let scheduler = TestScheduler()
            try await SessionPersistence.withTemporarySupportDirectoryAsync(
                directory.url, sleep: { await scheduler.wait(for: $0) }
            ) {
                let store = Self.store()
                SessionPersistence.save(store) { _ in Issue.record("cancelled checkpoint completed") }
                #expect(await waitUntil { scheduler.sleeperCount == 1 })
                let url = directory.url.appending(path: "session-state.json")
                let protected = Data("{invalid-json".utf8)
                if recovery {
                    try protected.write(to: url)
                    #expect(SessionPersistence.load().recoveryWarning?.preventsInitialSave == true)
                } else {
                    SessionPersistence.restoreWorkspacesDidTurnOff()
                }
                scheduler.advanceOneCycle()
                await drainMainQueue()
                if recovery {
                    #expect(try Data(contentsOf: url) == protected)
                } else {
                    #expect(!FileManager.default.fileExists(atPath: url.path))
                    #expect(SessionPersistence.validateSnapshotForNewlyEnabledRestore() == nil)
                    var completed = false
                    SessionPersistence.save(store) { _ in completed = true }
                    #expect(await waitUntil { scheduler.sleeperCount == 1 })
                    scheduler.advanceOneCycle()
                    #expect(await waitUntilEventually { completed })
                    #expect(try Self.read(directory.url).groups[0].name == "initial")
                }
            }
        }

        @Test("a delayed older write cannot overwrite a checkpoint or quit flush", arguments: [false, true])
        func delayedOlderWriteCannotRegress(flush: Bool) async throws {
            let directory = try TemporaryDirectory(prefix: "session-checkpoint-order")
            let scheduler = TestScheduler()
            let writeGate = AsyncGate()
            try await SessionPersistence.withTemporarySupportDirectoryAsync(
                directory.url,
                sleep: { await scheduler.wait(for: $0) },
                beforeAutomaticWrite: {
                    // Only the first dispatched write is held; a newer one can
                    // finish first, exercising the stale-writer ordering.
                    await Self.holdFirstWrite(writeGate)
                }
            ) {
                let store = Self.store()
                SessionPersistence.save(store) { _ in Issue.record("superseded write completed") }
                #expect(await waitUntil { scheduler.sleeperCount == 1 })
                scheduler.advanceOneCycle()
                #expect(await waitUntil { writeGate.waiterCount == 1 })
                let olderWrite = try #require(SessionPersistence.pendingWrite)
                _ = store.renameGroup(id: store.groups[0].id, to: "newer")
                var completed = false
                SessionPersistence.save(store) { _ in completed = true }
                #expect(await waitUntil { scheduler.sleeperCount == 1 })
                if flush {
                    #expect(throws: Never.self) { try SessionPersistence.flush(store).get() }
                    scheduler.advanceOneCycle()
                    await drainMainQueue()
                    #expect(!completed)
                } else {
                    scheduler.advanceOneCycle()
                    #expect(await waitUntilEventually { completed })
                }
                #expect(try Self.read(directory.url).groups[0].name == "newer")
                writeGate.open()
                await olderWrite.value
                #expect(try Self.read(directory.url).groups[0].name == "newer")
            }
        }

        private static func holdFirstWrite(_ gate: AsyncGate) async {
            if gate.waitCallCount == 0 { await gate.wait() }
        }

        private static func store() -> SessionStore {
            let pane = TerminalPane(title: "shell", workingDirectory: "~", executionPlan: .local)
            let session = TerminalSession(
                title: "shell", workingDirectory: "~", agentKind: .shell, agentState: .idle,
                layout: .pane(pane), activePaneID: pane.id
            )
            return SessionStore(
                restoring: SessionSnapshot(
                    groups: [SessionGroup(name: "initial", sessions: [session])], selectedSessionID: session.id
                ))
        }

        private static func read(_ directory: URL) throws -> SessionSnapshot {
            try SessionSnapshot.decode(from: Data(contentsOf: directory.appending(path: "session-state.json")))
        }
    }
}
