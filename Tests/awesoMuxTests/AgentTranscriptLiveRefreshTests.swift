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
            watch: FakeWatch().operation
        )
        let task = Task { await loop.run() }
        #expect(await waitUntil { scheduler.sleeperCount == 1 })

        task.cancel()
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
        let rediscover: [AgentTranscriptOpenFailure] = [
            .cacheWriteFailed,
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

    @Test("a cache-write failure rediscovers, and three failed rediscoveries stop the loop")
    func cacheWriteFailureRediscoversUpToTheBound() async throws {
        let discoveries = try await discoveryCount(whenRefreshFailsWith: .cacheWriteFailed)
        #expect(
            discoveries == 1 + AgentTranscriptLiveRefresh.maximumRediscoveries,
            "the initial discovery plus three bounded rediscoveries"
        )
    }

    @Test("a wrong-owner refusal gives up without rediscovering")
    func wrongOwnerGivesUp() async throws {
        let discoveries = try await discoveryCount(
            whenRefreshFailsWith: .unavailable(.unreadable(.wrongOwner))
        )
        #expect(discoveries == 1, "a security refusal is not a transient")
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

    /// The documented three-attempt recovery has to be reachable from a
    /// *discovery* failure too. Erasing the reason to `nil` made every lookup
    /// failure terminal on the first attempt, which is not what the table says.
    @Test("a retryable discovery failure consumes the rediscovery budget")
    func retryableDiscoveryFailureConsumesTheBudget() async throws {
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
            watch: FakeWatch().operation
        )
        await loop.run()
        #expect(
            discoveries.startCount == 1 + AgentTranscriptLiveRefresh.maximumRediscoveries,
            "the first attempt plus three bounded retries"
        )
    }

    // MARK: - Cancellation during discovery

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

    /// The bound means three failures *in a row*. A long session that hits
    /// three unrelated transient blips has recovered from each of them, and a
    /// lifetime budget would silently stop refreshing a tab that is working.
    @Test("a successful render resets the rediscovery budget")
    func aSuccessfulRenderResetsTheBudget() async throws {
        let directory = try TemporaryDirectory(prefix: "awesomux-live-refresh")
        defer { withExtendedLifetime(directory) {} }
        let discovered = try transcript(in: directory)
        let discoveries = RenderRecorder()
        let watch = FakeWatch()
        // Two isolated blips, each recovered from, then a run of three. Under a
        // lifetime budget the third blip is terminal and discovery #4 is the
        // last one that ever runs.
        let outcomes = RefreshScript([
            .failure(.cacheWriteFailed),
            .success(renderedCacheURL),
            .failure(.cacheWriteFailed),
            .success(renderedCacheURL),
            .failure(.cacheWriteFailed),
            .failure(.cacheWriteFailed),
            .failure(.cacheWriteFailed),
        ])

        let loop = AgentTranscriptLiveRefresh(
            gate: AgentTranscriptRenderGate(),
            pinned: nil,
            onPin: { _ in },
            discover: {
                await discoveries.began()
                return .success(discovered)
            },
            refresh: { _, _ in
                let outcome = await outcomes.next()
                // A successful render parks the loop on its watcher; feed it the
                // event that drives the next scripted outcome.
                if case .success = outcome { await watch.tick() }
                return outcome
            },
            watch: watch.operation
        )
        await loop.run()

        #expect(await outcomes.isExhausted, "every scripted outcome should have been consumed")
        #expect(
            discoveries.startCount == 6,
            "a reset budget survives two recovered blips and stops on the third consecutive run"
        )
    }

    /// Runs a loop whose refresh always fails with `failure` and whose
    /// discovery always succeeds, and reports how many full discoveries it ran
    /// before stopping. The loop terminates on its own — no cancellation.
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
            pinned: nil,
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
    private(set) var watchedURLs: [URL] = []
    private(set) var stopCount = 0
    private var onChange: (@MainActor () -> Void)?

    var isWatching: Bool { onChange != nil }

    var operation: AgentTranscriptLiveRefresh.WatchOperation {
        { url, callback in
            self.watchedURLs.append(url)
            self.onChange = callback
            return {
                self.stopCount += 1
                self.onChange = nil
            }
        }
    }

    func tick() { onChange?() }
}

/// Hands out one scripted refresh outcome per call, so a test can describe a
/// run of failures and recoveries without a clock. Past the end it keeps
/// failing, so a loop under test terminates on its own budget rather than
/// spinning on manufactured successes.
@MainActor
private final class RefreshScript {
    private var remaining: [Result<URL, AgentTranscriptOpenFailure>]

    var isExhausted: Bool { remaining.isEmpty }

    init(_ outcomes: [Result<URL, AgentTranscriptOpenFailure>]) {
        remaining = outcomes
    }

    func next() -> Result<URL, AgentTranscriptOpenFailure> {
        remaining.isEmpty ? .failure(.cacheWriteFailed) : remaining.removeFirst()
    }
}

@MainActor
private final class RenderRecorder {
    private(set) var startCount = 0

    func began() { startCount += 1 }
    func count() { startCount += 1 }
}

@MainActor
private final class CacheRecorder {
    private(set) var writes: [String] = []

    func write(_ contents: String) { writes.append(contents) }
}
