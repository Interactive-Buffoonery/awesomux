import AwesoMuxBridgeProtocol
import AwesoMuxTestSupport
import Foundation
import SecureFileIO
import Testing

@testable import AwesoMuxCore
@testable import awesoMux

/// The slot a successful render reports. Never written by these tests — the
/// injected refresh stands in for the render-and-store step.
private let renderedCacheURL = URL(fileURLWithPath: "/tmp/awesomux-test-cache.transcript.md")

/// Exercises the refresh loop through its injected seams: no real filesystem
/// watcher, no real renderer, no clock. The wiring to real files lives in
/// `AgentTranscriptLiveRefreshWatchTests`.
@MainActor
@Suite("Agent transcript live refresh")
struct AgentTranscriptLiveRefreshTests {
    private static let sessionID = "9f1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d"

    // MARK: - Fixtures

    /// A minimal `AgentTranscript`. The loop only ever reads `resolvedURL` from
    /// it and hands the value back to the injected refresh, so one real file is
    /// enough to mint one — and there is no way to mint one without a file,
    /// which is the point of the typed re-open seam.
    private func transcript(in directory: TemporaryDirectory) throws -> AgentTranscript {
        let url = directory.url.appending(path: "\(Self.sessionID).jsonl")
        try Data("{}\n".utf8).write(to: url)
        return AgentTranscript(
            agentKind: .claudeCode,
            sessionID: Self.sessionID,
            handle: try SecureFileReader.open(at: url)
        )
    }

    // MARK: - Coalescing and overlap

    @Test("a burst of ticks collapses to one follow-up render, and renders never overlap")
    func burstCollapsesToOneFollowUp() async throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-live-refresh")
        defer { withExtendedLifetime(directory) {} }
        let pinned = try transcript(in: directory)
        let scheduler = TestScheduler()
        let renders = RenderRecorder()
        let watch = FakeWatch()

        let loop = AgentTranscriptLiveRefresh(
            gate: AgentTranscriptRenderGate(),
            pinned: pinned,
            onPin: { _ in },
            discover: { .failure(.unreadable(.wrongOwner)) },
            refresh: { _, _ in
                await renders.began()
                await scheduler.wait(for: .zero)
                return .success(renderedCacheURL)
            },
            watch: watch.operation
        )
        let task = Task { await loop.run() }

        // The catch-up render is in flight and parked. Waiting on the gate's
        // waiter count rather than on `startCount` is load-bearing: the recorder
        // is touched BEFORE the park, so releasing on `startCount` alone can
        // open a cycle the render has not yet joined, and it then waits on the
        // next cycle's gate forever.
        #expect(await waitUntil { scheduler.sleeperCount == 1 })
        #expect(renders.startCount == 1)

        // Five events while it is parked. `.bufferingNewest(1)` keeps one.
        for _ in 0..<5 { watch.tick() }
        await drainMainQueue()
        #expect(renders.startCount == 1, "a second render must not start while the first is running")

        scheduler.advanceOneCycle()
        #expect(await waitUntil { scheduler.sleeperCount == 1 })
        #expect(renders.startCount == 2)

        scheduler.advanceOneCycle()
        await drainMainQueue()
        #expect(renders.startCount == 2, "five events must collapse to a single follow-up render")

        task.cancel()
        await task.value
    }

    // MARK: - Generation ordering

    /// The backwards-movement bug. Nothing else in the suite catches it:
    /// `.task(id:)` cancellation cannot reach an already-dispatched detached
    /// render, so without the gate the old render's bytes land last.
    @Test("a superseded render cannot commit")
    func supersededRenderCannotCommit() async throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-live-refresh")
        defer { withExtendedLifetime(directory) {} }
        let pinned = try transcript(in: directory)
        // One gate across both generations, exactly as the view's `@State`
        // holds it across a `.task(id:)` change.
        let gate = AgentTranscriptRenderGate()
        let cache = CacheRecorder()
        let scheduler = TestScheduler()

        let superseded = AgentTranscriptLiveRefresh(
            gate: gate,
            pinned: pinned,
            onPin: { _ in },
            discover: { .failure(.unreadable(.wrongOwner)) },
            refresh: { _, shouldCommit in
                await scheduler.wait(for: .zero)
                if shouldCommit() { await cache.write("old") }
                return .success(renderedCacheURL)
            },
            watch: FakeWatch().operation
        )
        let supersededTask = Task { await superseded.run() }
        #expect(await waitUntil { scheduler.sleeperCount == 1 })

        supersededTask.cancel()

        let current = AgentTranscriptLiveRefresh(
            gate: gate,
            pinned: pinned,
            onPin: { _ in },
            discover: { .failure(.unreadable(.wrongOwner)) },
            refresh: { _, shouldCommit in
                if shouldCommit() { await cache.write("new") }
                return .success(renderedCacheURL)
            },
            watch: FakeWatch().operation
        )
        let currentTask = Task { await current.run() }
        #expect(await waitUntil { cache.writes == ["new"] })

        // Release the superseded render only now, so it finishes last.
        scheduler.advanceOneCycle()
        await supersededTask.value
        currentTask.cancel()
        await currentTask.value

        #expect(cache.writes == ["new"], "a late render must not overwrite newer cache bytes")
    }

    /// The successor-free half of the same rule: cancelling has to reach a
    /// render that is already dispatched, which `Task.isCancelled` cannot do
    /// from inside a detached task.
    @Test("a cancelled loop's in-flight render cannot commit")
    func cancelledRenderCannotCommit() async throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-live-refresh")
        defer { withExtendedLifetime(directory) {} }
        let pinned = try transcript(in: directory)
        let cache = CacheRecorder()
        let scheduler = TestScheduler()
        let watch = FakeWatch()

        let loop = AgentTranscriptLiveRefresh(
            gate: AgentTranscriptRenderGate(),
            pinned: pinned,
            onPin: { _ in },
            discover: { .failure(.unreadable(.wrongOwner)) },
            refresh: { _, shouldCommit in
                await scheduler.wait(for: .zero)
                if shouldCommit() { await cache.write("cancelled") }
                return .success(renderedCacheURL)
            },
            watch: watch.operation
        )
        let task = Task { await loop.run() }
        #expect(await waitUntil { scheduler.sleeperCount == 1 })

        task.cancel()
        await drainMainQueue()
        #expect(
            watch.stopCount == 1,
            "cancellation must stop the exact watcher before detached rendering returns"
        )
        scheduler.advanceOneCycle()
        await task.value

        #expect(cache.writes.isEmpty, "a cancelled render must not reach the cache")
    }

    // MARK: - Cancellation

    @Test("cancellation stops the watcher and no further render runs")
    func cancellationStopsTheWatcher() async throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-live-refresh")
        defer { withExtendedLifetime(directory) {} }
        let pinned = try transcript(in: directory)
        let renders = RenderRecorder()
        let watch = FakeWatch()

        let loop = AgentTranscriptLiveRefresh(
            gate: AgentTranscriptRenderGate(),
            pinned: pinned,
            onPin: { _ in },
            discover: { .failure(.unreadable(.wrongOwner)) },
            refresh: { _, _ in
                await renders.began()
                return .success(renderedCacheURL)
            },
            watch: watch.operation
        )
        let task = Task { await loop.run() }

        #expect(await waitUntil { renders.startCount == 1 && watch.isWatching })
        #expect(watch.watchedURLs == [pinned.resolvedURL])

        task.cancel()
        await task.value

        #expect(watch.stopCount == 1)
        #expect(!watch.isWatching)

        watch.tick()
        await drainMainQueue()
        #expect(renders.startCount == 1, "no render may run after cancellation")
    }

    // MARK: - Failure mapping

    @Test("every refresh failure maps to its documented response")
    func failureResponses() {
        #expect(
            AgentTranscriptLiveRefresh.response(to: .cacheWriteFailed) == .continueFollowing
        )
        let rediscover: [AgentTranscriptOpenFailure] = [
            .unavailable(.notFound),
            .unavailable(.unreadable(.unreadable)),
        ]
        let giveUp: [AgentTranscriptOpenFailure] = [
            .unavailable(.unreadable(.wrongOwner)),
            .unavailable(.unreadable(.notRegularFile)),
            .unavailable(.unreadable(.tooLarge)),
            .unavailable(.remoteExecution),
            .unavailable(.unsupportedAgent(.grok)),
            .unavailable(.invalidSessionID),
            .unavailable(.noSessionIdentity),
            .unavailable(.searchLimitReached),
        ]
        for failure in rediscover {
            #expect(
                AgentTranscriptLiveRefresh.response(to: failure) == .rediscover,
                "\(failure) should rediscover"
            )
        }
        for failure in giveUp {
            #expect(
                AgentTranscriptLiveRefresh.response(to: failure) == .giveUp,
                "\(failure) should give up"
            )
        }
    }

    @Test("a cache-write failure keeps the exact watcher and a later append retries")
    func cacheWriteFailureKeepsFollowing() async throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-live-refresh")
        defer { withExtendedLifetime(directory) {} }
        let pinned = try transcript(in: directory)
        let discoveries = RenderRecorder()
        let renders = RenderRecorder()
        let watch = FakeWatch()

        let loop = AgentTranscriptLiveRefresh(
            gate: AgentTranscriptRenderGate(),
            pinned: pinned,
            onPin: { _ in },
            discover: {
                await discoveries.began()
                return .failure(.notFound)
            },
            refresh: { _, _ in
                let count = await renders.beganAndCount()
                return count == 1
                    ? .failure(.cacheWriteFailed)
                    : .success(renderedCacheURL)
            },
            watch: watch.operation
        )
        let task = Task { await loop.run() }

        #expect(await waitUntil { renders.startCount == 1 && watch.isWatching })
        #expect(watch.watchedURLs == [pinned.resolvedURL])
        #expect(discoveries.startCount == 0, "a cache failure must not rediscover the source")

        watch.tick()
        #expect(await waitUntil { renders.startCount == 2 })
        #expect(discoveries.startCount == 0)
        #expect(watch.watchedURLs == [pinned.resolvedURL], "the exact watcher must stay pinned")

        task.cancel()
        await task.value
    }

    @Test("a wrong-owner refusal gives up without rediscovering")
    func wrongOwnerGivesUp() async throws {
        let discoveries = try await discoveryCount(
            whenRefreshFailsWith: .unavailable(.unreadable(.wrongOwner))
        )
        #expect(discoveries == 0, "a security refusal must not rediscover")
    }

    @Test("a discovery refusal gives up at once, without rendering or retrying")
    func failedDiscoveryGivesUp() async throws {
        let renders = RenderRecorder()
        let discoveries = RenderRecorder()
        let loop = AgentTranscriptLiveRefresh(
            gate: AgentTranscriptRenderGate(),
            pinned: nil,
            onPin: { _ in },
            discover: {
                await discoveries.began()
                return .failure(.unreadable(.wrongOwner))
            },
            refresh: { _, _ in
                await renders.began()
                return .success(renderedCacheURL)
            },
            watch: FakeWatch().operation
        )
        await loop.run()
        #expect(renders.startCount == 0)
        #expect(discoveries.startCount == 1, "a security refusal is not a transient")
    }

    @Test("source recovery probes once, then waits for a directory event")
    func sourceRecoveryDoesNotSpinSynchronously() async throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-live-refresh")
        defer { withExtendedLifetime(directory) {} }
        let pinned = try transcript(in: directory)
        let discoveries = RenderRecorder()
        let watch = FakeWatch()
        let loop = AgentTranscriptLiveRefresh(
            gate: AgentTranscriptRenderGate(),
            pinned: pinned,
            onPin: { _ in },
            discover: {
                await discoveries.began()
                return .failure(.unreadable(.unreadable))
            },
            refresh: { _, _ in .failure(.unavailable(.unreadable(.unreadable))) },
            watch: watch.operation
        )
        let task = Task { await loop.run() }

        #expect(await waitUntil { discoveries.startCount >= 1 })
        await drainMainQueue()
        #expect(discoveries.startCount == 1, "recovery must park after its catch-up probe")
        #expect(
            watch.watchedURLs == [
                pinned.resolvedURL,
                pinned.resolvedURL.deletingLastPathComponent(),
            ],
            "recovery must move from the exact file to its session directory"
        )
        #expect(watch.isWatching)

        task.cancel()
        await task.value
    }

    @Test("each recovery directory event authorizes one discovery")
    func oneDiscoveryPerRecoveryEvent() async throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-live-refresh")
        defer { withExtendedLifetime(directory) {} }
        let pinned = try transcript(in: directory)
        let discoveries = RenderRecorder()
        let watch = FakeWatch()
        let loop = AgentTranscriptLiveRefresh(
            gate: AgentTranscriptRenderGate(),
            pinned: pinned,
            onPin: { _ in },
            discover: {
                await discoveries.began()
                return .failure(.notFound)
            },
            refresh: { _, _ in .failure(.unavailable(.notFound)) },
            watch: watch.operation
        )
        let task = Task { await loop.run() }

        #expect(await waitUntil { discoveries.startCount == 1 && watch.isWatching })
        watch.tick()
        #expect(await waitUntil { discoveries.startCount == 2 })
        await drainMainQueue()
        #expect(discoveries.startCount == 2)
        #expect(watch.isWatching, "two failures leave one recovery attempt available")

        task.cancel()
        await task.value
    }

    @Test("the third event-driven source recovery failure exhausts the bound")
    func sourceRecoveryExhaustsAtTheBound() async throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-live-refresh")
        defer { withExtendedLifetime(directory) {} }
        let pinned = try transcript(in: directory)
        let discoveries = RenderRecorder()
        let watch = FakeWatch()
        let loop = AgentTranscriptLiveRefresh(
            gate: AgentTranscriptRenderGate(),
            pinned: pinned,
            onPin: { _ in },
            discover: {
                await discoveries.began()
                return .failure(.notFound)
            },
            refresh: { _, _ in .failure(.unavailable(.notFound)) },
            watch: watch.operation
        )
        let task = Task { await loop.run() }

        #expect(await waitUntil { discoveries.startCount == 1 })
        watch.tick()
        #expect(await waitUntil { discoveries.startCount == 2 })
        watch.tick()
        await task.value

        #expect(discoveries.startCount == AgentTranscriptLiveRefresh.maximumRediscoveries)
        #expect(!watch.isWatching)
        #expect(watch.stopCount == 2, "both exact-file and recovery watchers must stop")
    }

    @Test("successful recovery re-pins and resumes exact-file watching")
    func successfulRecoveryResumesExactWatching() async throws {
        let oldDirectory = try TemporaryDirectory(prefix: "awesomux-live-refresh-old")
        let newDirectory = try TemporaryDirectory(prefix: "awesomux-live-refresh-new")
        defer {
            withExtendedLifetime(oldDirectory) {}
            withExtendedLifetime(newDirectory) {}
        }
        let old = try transcript(in: oldDirectory)
        let recovered = try transcript(in: newDirectory)
        let providerRoot = oldDirectory.url.deletingLastPathComponent()
        let discoveries = DiscoveryScript([.failure(.notFound), .success(recovered)])
        let pins = RenderRecorder()
        let renders = RenderRecorder()
        let watch = FakeWatch()
        let loop = AgentTranscriptLiveRefresh(
            gate: AgentTranscriptRenderGate(),
            pinned: old,
            onPin: { _ in pins.count() },
            discover: { await discoveries.next() },
            refresh: { transcript, _ in
                await renders.began()
                return transcript.resolvedURL == old.resolvedURL
                    ? .failure(.unavailable(.notFound))
                    : .success(renderedCacheURL)
            },
            watch: watch.operation,
            recoveryWatchURL: providerRoot
        )
        let task = Task { await loop.run() }

        #expect(await waitUntil { discoveries.callCount == 1 && watch.isWatching })
        watch.tick()
        #expect(
            await waitUntil {
                pins.startCount == 1 && watch.watchedURLs.last == recovered.resolvedURL
                    && renders.startCount == 2
            }
        )
        #expect(
            watch.watchedURLs == [
                old.resolvedURL,
                providerRoot,
                recovered.resolvedURL,
            ]
        )

        task.cancel()
        await task.value
    }

    @Test("a recovered pin that vanishes without an event waits for a directory event")
    func recoveredPinFailureWithoutAnEventDoesNotSpinDiscovery() async throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-live-refresh")
        defer { withExtendedLifetime(directory) {} }
        let transcript = try transcript(in: directory)
        let discoveries = RenderRecorder()
        let scheduler = TestScheduler()
        let watch = FakeWatch()
        let loop = AgentTranscriptLiveRefresh(
            gate: AgentTranscriptRenderGate(),
            pinned: transcript,
            onPin: { _ in },
            discover: {
                let count = await discoveries.beganAndCount()
                if count > 1 { await scheduler.wait(for: .zero) }
                return .success(transcript)
            },
            refresh: { _, _ in .failure(.unavailable(.notFound)) },
            watch: watch.operation
        )
        let task = Task { await loop.run() }

        #expect(await waitUntil { watch.watchedURLs.count == 3 })
        await drainMainQueue()
        #expect(
            discoveries.startCount == 1,
            "a rediscovered source that immediately vanishes must wait for a new event"
        )

        task.cancel()
        scheduler.advanceOneCycle()
        await task.value
    }

    @Test("an event delivered during a recovered pin's first render is not lost")
    func recoveredPinPreservesBufferedReplacementEvent() async throws {
        let oldDirectory = try TemporaryDirectory(prefix: "awesomux-live-refresh-old")
        let newDirectory = try TemporaryDirectory(prefix: "awesomux-live-refresh-new")
        defer {
            withExtendedLifetime(oldDirectory) {}
            withExtendedLifetime(newDirectory) {}
        }
        let old = try transcript(in: oldDirectory)
        let recovered = try transcript(in: newDirectory)
        let discoveries = DiscoveryScript([.success(recovered), .success(recovered)])
        let scheduler = TestScheduler()
        let renders = RenderRecorder()
        let watch = FakeWatch()
        let loop = AgentTranscriptLiveRefresh(
            gate: AgentTranscriptRenderGate(),
            pinned: old,
            onPin: { _ in },
            discover: { await discoveries.next() },
            refresh: { transcript, _ in
                let count = await renders.beganAndCount()
                if transcript.resolvedURL == old.resolvedURL {
                    return .failure(.unavailable(.notFound))
                }
                if count == 2 {
                    await scheduler.wait(for: .zero)
                    return .failure(.unavailable(.notFound))
                }
                return .success(renderedCacheURL)
            },
            watch: watch.operation
        )
        let task = Task { await loop.run() }

        #expect(await waitUntil { scheduler.sleeperCount == 1 && watch.isWatching })
        watch.tick()
        scheduler.advanceOneCycle()
        #expect(
            await waitUntil { discoveries.callCount == 2 && renders.startCount == 3 },
            "the buffered replacement event must authorize the next discovery"
        )

        task.cancel()
        await task.value
    }

    @Test("one buffered hierarchy event cannot authorize discovery twice")
    func recoveredPinConsumesBufferedReplacementEventOnce() async throws {
        let oldDirectory = try TemporaryDirectory(prefix: "awesomux-live-refresh-old")
        let newDirectory = try TemporaryDirectory(prefix: "awesomux-live-refresh-new")
        defer {
            withExtendedLifetime(oldDirectory) {}
            withExtendedLifetime(newDirectory) {}
        }
        let old = try transcript(in: oldDirectory)
        let recovered = try transcript(in: newDirectory)
        let discoveries = DiscoveryScript([.success(recovered), .success(recovered)])
        let scheduler = TestScheduler()
        let renders = RenderRecorder()
        let exactWatch = FakeWatch()
        let recoveryWatch = FakeWatch()
        let loop = AgentTranscriptLiveRefresh(
            gate: AgentTranscriptRenderGate(),
            pinned: old,
            onPin: { _ in },
            discover: { await discoveries.next() },
            refresh: { transcript, _ in
                let count = await renders.beganAndCount()
                if transcript.resolvedURL == old.resolvedURL {
                    return .failure(.unavailable(.notFound))
                }
                if count == 2 {
                    await scheduler.wait(for: .zero)
                }
                return .failure(.unavailable(.notFound))
            },
            watch: exactWatch.operation,
            recoveryWatch: recoveryWatch.operation
        )
        let task = Task { await loop.run() }

        #expect(await waitUntil { scheduler.sleeperCount == 1 && recoveryWatch.isWatching })
        recoveryWatch.tick()
        scheduler.advanceOneCycle()
        #expect(
            await waitUntil { discoveries.callCount >= 2 && renders.startCount >= 3 },
            "the buffered hierarchy event must authorize one replacement discovery"
        )
        await drainMainQueue()
        #expect(discoveries.callCount == 2, "one event must not be consumed a second time")

        task.cancel()
        await task.value
    }

    @Test("an unarmed recovery watcher terminates without a discovery")
    func unarmedRecoveryWatcherDoesNotPark() async {
        let discoveries = RenderRecorder()
        let loop = AgentTranscriptLiveRefresh(
            gate: AgentTranscriptRenderGate(),
            pinned: nil,
            onPin: { _ in },
            discover: {
                await discoveries.began()
                return .failure(.notFound)
            },
            refresh: { _, _ in .success(renderedCacheURL) },
            watch: FakeWatch(arms: false).operation,
            recoveryWatchURL: URL(fileURLWithPath: "/tmp/provider")
        )

        await loop.run()

        #expect(discoveries.startCount == 0)
    }

    @Test("a security refusal during recovery gives up immediately")
    func recoverySecurityRefusalGivesUp() async throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-live-refresh")
        defer { withExtendedLifetime(directory) {} }
        let pinned = try transcript(in: directory)
        let discoveries = RenderRecorder()
        let watch = FakeWatch()
        let loop = AgentTranscriptLiveRefresh(
            gate: AgentTranscriptRenderGate(),
            pinned: pinned,
            onPin: { _ in },
            discover: {
                await discoveries.began()
                return .failure(.unreadable(.wrongOwner))
            },
            refresh: { _, _ in .failure(.unavailable(.notFound)) },
            watch: watch.operation
        )

        await loop.run()

        #expect(discoveries.startCount == 1)
        #expect(!watch.isWatching)
        #expect(watch.stopCount == 2)
    }

    @Test("cancellation tears down an armed recovery watcher")
    func cancellationStopsRecoveryWatcher() async throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-live-refresh")
        defer { withExtendedLifetime(directory) {} }
        let pinned = try transcript(in: directory)
        let discoveries = RenderRecorder()
        let watch = FakeWatch()
        let loop = AgentTranscriptLiveRefresh(
            gate: AgentTranscriptRenderGate(),
            pinned: pinned,
            onPin: { _ in },
            discover: {
                await discoveries.began()
                return .failure(.notFound)
            },
            refresh: { _, _ in .failure(.unavailable(.notFound)) },
            watch: watch.operation
        )
        let task = Task { await loop.run() }
        #expect(await waitUntil { discoveries.startCount == 1 && watch.isWatching })

        task.cancel()
        await task.value
        watch.tick()
        await drainMainQueue()

        #expect(discoveries.startCount == 1)
        #expect(!watch.isWatching)
        #expect(watch.stopCount == 2)
    }

    @Test("cancellation stops the recovery watcher while discovery is in flight")
    func cancellationStopsRecoveryWatcherDuringDiscovery() async throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-live-refresh")
        defer { withExtendedLifetime(directory) {} }
        let pinned = try transcript(in: directory)
        let scheduler = TestScheduler()
        let watch = FakeWatch()
        let loop = AgentTranscriptLiveRefresh(
            gate: AgentTranscriptRenderGate(),
            pinned: pinned,
            onPin: { _ in },
            discover: {
                await scheduler.wait(for: .zero)
                return .failure(.notFound)
            },
            refresh: { _, _ in .failure(.unavailable(.notFound)) },
            watch: watch.operation
        )
        let task = Task { await loop.run() }
        #expect(await waitUntil { scheduler.sleeperCount == 1 && watch.isWatching })

        task.cancel()
        await drainMainQueue()
        #expect(
            watch.stopCount == 2,
            "cancellation must stop the recovery watcher before detached discovery returns"
        )

        scheduler.advanceOneCycle()
        await task.value
    }

    // MARK: - Cancellation during discovery

    @Test("the recovery directory is armed before catch-up discovery")
    func recoveryArmsBeforeCatchUpDiscovery() async throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-live-refresh")
        defer { withExtendedLifetime(directory) {} }
        let observations = BooleanRecorder()
        let watch = FakeWatch()
        let loop = AgentTranscriptLiveRefresh(
            gate: AgentTranscriptRenderGate(),
            pinned: nil,
            onPin: { _ in },
            discover: {
                let armed = await MainActor.run {
                    watch.isWatching && watch.watchedURLs == [directory.url]
                }
                await observations.record(armed)
                return .failure(.unreadable(.wrongOwner))
            },
            refresh: { _, _ in .success(renderedCacheURL) },
            watch: watch.operation,
            recoveryWatchURL: directory.url
        )

        await loop.run()

        #expect(await observations.values == [true])
        #expect(watch.stopCount == 1)
        #expect(!watch.isWatching)
    }

    @Test("an initial missing source recovers on a provider-directory event")
    func initialMissingSourceRecoversFromDirectoryEvent() async throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-live-refresh")
        defer { withExtendedLifetime(directory) {} }
        let discovered = try transcript(in: directory)
        let discoveries = DiscoveryScript([.failure(.notFound), .success(discovered)])
        let renders = RenderRecorder()
        let watch = FakeWatch()
        let loop = AgentTranscriptLiveRefresh(
            gate: AgentTranscriptRenderGate(),
            pinned: nil,
            onPin: { _ in },
            discover: { await discoveries.next() },
            refresh: { _, _ in
                await renders.began()
                return .success(renderedCacheURL)
            },
            watch: watch.operation,
            recoveryWatchURL: directory.url
        )
        let task = Task { await loop.run() }

        #expect(await waitUntil { discoveries.callCount == 1 && watch.isWatching })
        watch.tick()
        #expect(await waitUntil { discoveries.callCount == 2 && renders.startCount == 1 })

        task.cancel()
        await task.value
    }

    @Test("a burst of recovery events buffers only one follow-up discovery")
    func recoveryEventBurstCoalesces() async throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-live-refresh")
        defer { withExtendedLifetime(directory) {} }
        let pinned = try transcript(in: directory)
        let discoveries = RenderRecorder()
        let scheduler = TestScheduler()
        let watch = FakeWatch()
        let loop = AgentTranscriptLiveRefresh(
            gate: AgentTranscriptRenderGate(),
            pinned: pinned,
            onPin: { _ in },
            discover: {
                await discoveries.began()
                await scheduler.wait(for: .zero)
                return .failure(.notFound)
            },
            refresh: { _, _ in .failure(.unavailable(.notFound)) },
            watch: watch.operation
        )
        let task = Task { await loop.run() }
        #expect(await waitUntil { scheduler.sleeperCount == 1 })

        for _ in 0..<5 { watch.tick() }
        scheduler.advanceOneCycle()
        #expect(await waitUntil { scheduler.sleeperCount == 1 && discoveries.startCount == 2 })
        scheduler.advanceOneCycle()
        await drainMainQueue()

        #expect(discoveries.startCount == 2, "five events must buffer one follow-up discovery")
        task.cancel()
        await task.value
    }

    /// `Task.detached` does not inherit cancellation, so discovery runs to
    /// completion after the enclosing `.task(id:)` has gone away. Everything
    /// downstream of it — pinning, the `@State` write through `onPin`, arming a
    /// watcher — would belong to a generation that no longer exists.
    @Test("a task cancelled during discovery pins nothing and arms no watcher")
    func cancellationDuringDiscoveryStopsBeforePinning() async throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-live-refresh")
        defer { withExtendedLifetime(directory) {} }
        let discovered = try transcript(in: directory)
        let scheduler = TestScheduler()
        let pins = RenderRecorder()
        let renders = RenderRecorder()
        let watch = FakeWatch()

        let loop = AgentTranscriptLiveRefresh(
            gate: AgentTranscriptRenderGate(),
            pinned: nil,
            onPin: { _ in pins.count() },
            discover: {
                await scheduler.wait(for: .zero)
                return .success(discovered)
            },
            refresh: { _, _ in
                await renders.began()
                return .success(renderedCacheURL)
            },
            watch: watch.operation
        )
        let task = Task { await loop.run() }
        #expect(await waitUntil { scheduler.sleeperCount == 1 })

        task.cancel()
        scheduler.advanceOneCycle()
        await task.value

        #expect(pins.startCount == 0, "a cancelled task must not write the view's pinned state")
        #expect(watch.watchedURLs.isEmpty, "a cancelled task must not arm a watcher")
        #expect(renders.startCount == 0)
    }

    // MARK: - Budget

    @Test("a successful committed render resets the source-recovery budget")
    func successfulRenderResetsSourceRecoveryBudget() async throws {
        let oldDirectory = try TemporaryDirectory(prefix: "awesomux-live-refresh-old")
        let newDirectory = try TemporaryDirectory(prefix: "awesomux-live-refresh-new")
        defer {
            withExtendedLifetime(oldDirectory) {}
            withExtendedLifetime(newDirectory) {}
        }
        let old = try transcript(in: oldDirectory)
        let recovered = try transcript(in: newDirectory)
        let discoveries = DiscoveryScript([
            .failure(.notFound),
            .success(recovered),
            .failure(.notFound),
            .failure(.notFound),
            .failure(.notFound),
        ])
        let watch = FakeWatch()
        let outcomes = RefreshScript([
            .failure(.unavailable(.notFound)),
            .success(renderedCacheURL),
            .failure(.unavailable(.notFound)),
        ])

        let loop = AgentTranscriptLiveRefresh(
            gate: AgentTranscriptRenderGate(),
            pinned: old,
            onPin: { _ in },
            discover: { await discoveries.next() },
            refresh: { _, _ in await outcomes.next() },
            watch: watch.operation
        )
        let task = Task { await loop.run() }

        #expect(await waitUntil { discoveries.callCount == 1 && watch.isWatching })
        watch.tick()
        #expect(
            await waitUntil {
                discoveries.callCount == 2 && outcomes.callCount == 2
                    && watch.watchedURLs.last == recovered.resolvedURL
            }
        )

        watch.tick()
        #expect(await waitUntil { discoveries.callCount == 3 && watch.isWatching })
        watch.tick()
        #expect(await waitUntil { discoveries.callCount == 4 && watch.isWatching })
        watch.tick()
        await task.value

        #expect(
            discoveries.callCount == 5,
            "the successful render must restore all three consecutive recovery attempts"
        )
    }

    @Test("a cache-write failure neither charges nor resets source recovery")
    func cacheFailureLeavesSourceRecoveryBudgetUntouched() async throws {
        let oldDirectory = try TemporaryDirectory(prefix: "awesomux-live-refresh-old")
        let newDirectory = try TemporaryDirectory(prefix: "awesomux-live-refresh-new")
        defer {
            withExtendedLifetime(oldDirectory) {}
            withExtendedLifetime(newDirectory) {}
        }
        let old = try transcript(in: oldDirectory)
        let recovered = try transcript(in: newDirectory)
        let discoveries = DiscoveryScript([
            .failure(.notFound),
            .success(recovered),
            .failure(.notFound),
            .failure(.notFound),
        ])
        let outcomes = RefreshScript([
            .failure(.unavailable(.notFound)),
            .failure(.cacheWriteFailed),
            .failure(.unavailable(.notFound)),
        ])
        let watch = FakeWatch()
        let loop = AgentTranscriptLiveRefresh(
            gate: AgentTranscriptRenderGate(),
            pinned: old,
            onPin: { _ in },
            discover: { await discoveries.next() },
            refresh: { _, _ in await outcomes.next() },
            watch: watch.operation
        )
        let task = Task { await loop.run() }

        #expect(await waitUntil { discoveries.callCount == 1 && watch.isWatching })
        watch.tick()
        #expect(
            await waitUntil {
                discoveries.callCount == 2 && outcomes.callCount == 2
                    && watch.watchedURLs.last == recovered.resolvedURL
            }
        )

        watch.tick()
        #expect(await waitUntil { discoveries.callCount == 3 && watch.isWatching })
        watch.tick()
        await task.value

        #expect(
            discoveries.callCount == 4,
            "the cache failure must leave the first source-recovery failure charged"
        )
    }

    /// Runs a pinned loop whose refresh always fails with `failure` and reports
    /// how many full discoveries it attempted before stopping. The loop
    /// terminates on its own — no cancellation.
    private func discoveryCount(
        whenRefreshFailsWith failure: AgentTranscriptOpenFailure
    ) async throws -> Int {
        let directory = try TemporaryDirectory(prefix: "awesomux-live-refresh")
        defer { withExtendedLifetime(directory) {} }
        let discovered = try transcript(in: directory)
        let discoveries = RenderRecorder()
        let pins = RenderRecorder()

        let loop = AgentTranscriptLiveRefresh(
            gate: AgentTranscriptRenderGate(),
            pinned: discovered,
            onPin: { _ in pins.count() },
            discover: {
                await discoveries.began()
                return .success(discovered)
            },
            refresh: { _, _ in .failure(failure) },
            watch: FakeWatch().operation
        )
        await loop.run()
        #expect(pins.startCount == discoveries.startCount, "every discovery re-pins the transcript")
        return discoveries.startCount
    }
}

// MARK: - Doubles

/// Hands the loop's tick callback back to the test, so events can be delivered
/// without a filesystem.
@MainActor
private final class FakeWatch {
    private let arms: Bool
    private(set) var watchedURLs: [URL] = []
    private(set) var stopCount = 0
    private var nextRegistrationID = 0
    private var callbacks: [Int: @MainActor () -> Void] = [:]

    var isWatching: Bool { !callbacks.isEmpty }

    init(arms: Bool = true) {
        self.arms = arms
    }

    var operation: AgentTranscriptLiveRefresh.WatchOperation {
        { url, callback in
            self.watchedURLs.append(url)
            guard self.arms else { return nil }
            let registrationID = self.nextRegistrationID
            self.nextRegistrationID += 1
            self.callbacks[registrationID] = callback
            return {
                self.stopCount += 1
                self.callbacks[registrationID] = nil
            }
        }
    }

    func tick() {
        for callback in callbacks.values { callback() }
    }
}

/// Hands out one scripted refresh outcome per call, so a test can describe a
/// run of failures and recoveries without a clock. Past the end it keeps
/// failing, so a loop under test terminates on its own budget rather than
/// spinning on manufactured successes.
@MainActor
private final class RefreshScript {
    private var remaining: [Result<URL, AgentTranscriptOpenFailure>]
    private(set) var callCount = 0

    var isExhausted: Bool { remaining.isEmpty }

    init(_ outcomes: [Result<URL, AgentTranscriptOpenFailure>]) {
        remaining = outcomes
    }

    func next() -> Result<URL, AgentTranscriptOpenFailure> {
        callCount += 1
        return remaining.isEmpty ? .failure(.cacheWriteFailed) : remaining.removeFirst()
    }
}

@MainActor
private final class DiscoveryScript {
    private var remaining: [Result<AgentTranscript, AgentTranscriptUnavailable>]
    private(set) var callCount = 0

    init(_ outcomes: [Result<AgentTranscript, AgentTranscriptUnavailable>]) {
        remaining = outcomes
    }

    func next() -> Result<AgentTranscript, AgentTranscriptUnavailable> {
        callCount += 1
        return remaining.isEmpty ? .failure(.notFound) : remaining.removeFirst()
    }
}

@MainActor
private final class RenderRecorder {
    private(set) var startCount = 0

    func began() { startCount += 1 }
    func beganAndCount() -> Int {
        startCount += 1
        return startCount
    }
    func count() { startCount += 1 }
}

@MainActor
private final class CacheRecorder {
    private(set) var writes: [String] = []

    func write(_ contents: String) { writes.append(contents) }
}

private actor BooleanRecorder {
    private(set) var values: [Bool] = []

    func record(_ value: Bool) { values.append(value) }
}
