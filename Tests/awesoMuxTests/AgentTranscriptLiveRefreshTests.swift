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
    enum ObsoleteRenderCannotCommitCase: String, CaseIterable {
        case supersededRenderCannotCommit
        case cancelledRenderCannotCommit
    }

    @Test(arguments: ObsoleteRenderCannotCommitCase.allCases)
    func obsoleteRenderCannotCommit(_ scenario: ObsoleteRenderCannotCommitCase) async throws {
        switch scenario {
        case .supersededRenderCannotCommit:
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
        case .cancelledRenderCannotCommit:
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
    }

    // MARK: - Failure mapping

    enum SecurityRefusalStopsFollowingCase: String, CaseIterable {
        case wrongOwnerGivesUp
        case failedDiscoveryGivesUp
        case recoverySecurityRefusalGivesUp
    }

    @Test(arguments: SecurityRefusalStopsFollowingCase.allCases)
    func securityRefusalStopsFollowing(_ scenario: SecurityRefusalStopsFollowingCase) async throws {
        switch scenario {
        case .wrongOwnerGivesUp:
            let discoveries = try await discoveryCount(
                whenRefreshFailsWith: .unavailable(.unreadable(.wrongOwner))
            )
            #expect(discoveries == 0, "a security refusal must not rediscover")
        case .failedDiscoveryGivesUp:
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
        case .recoverySecurityRefusalGivesUp:
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

        #expect(!watch.isWatching)
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
