import Foundation
import Testing
@testable import awesoMux

@Suite("Scrollback background extraction lifetime")
@MainActor
struct ScrollbackReadCoordinatorTests {
    @Test("cancelled reads retain native ownership until the worker finishes")
    func cancellationRetainsOwnership() async {
        let coordinator = ScrollbackReadCoordinator()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            await coordinator.read(surfaceID: 1) {
                #expect(!Thread.isMainThread)
                signal.yield(())
                signal.finish()
                release.wait()
                return .loaded("complete")
            }
        }
        for await _ in started { break }
        defer { release.signal() }
        task.cancel()
        var events: [String] = []
        #expect(coordinator.deferFree(surfaceID: 1) { events.append("free") })
        #expect(coordinator.deferReload { events.append("reload") })
        #expect(events.isEmpty)
        let rejected = await coordinator.read(surfaceID: 2) {
            Issue.record("must not start a new read while reload is pending")
            return .failed
        }
        #expect(rejected == .busy)
        release.signal()
        #expect(await task.value == .loaded("complete"))
        #expect(events == ["free", "reload"])
        #expect(!coordinator.deferFree(surfaceID: 1) { Issue.record("already released") })
        #expect(!coordinator.deferReload { Issue.record("already reloaded") })
    }

    @Test("a surface cannot accumulate concurrent reads")
    func rejectsOverlappingRead() async {
        let coordinator = ScrollbackReadCoordinator()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            await coordinator.read(surfaceID: 1) {
                signal.yield(())
                signal.finish()
                release.wait()
                return .tooLarge
            }
        }
        for await _ in started { break }
        defer { release.signal() }
        let result = await coordinator.read(surfaceID: 1) {
            Issue.record("must not run a second extraction for the same surface")
            return .loaded("unexpected")
        }
        #expect(result == .busy)
        release.signal()
        #expect(await task.value == .tooLarge)
        #expect(await coordinator.read(surfaceID: 1) { .loaded("next") } == .loaded("next"))
    }
    @Test("reload waits for every surface and runs after their frees")
    func reloadWaitsForAllSurfaces() async {
        let coordinator = ScrollbackReadCoordinator()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let firstRelease = DispatchSemaphore(value: 0)
        let secondRelease = DispatchSemaphore(value: 0)
        let first = Task {
            await coordinator.read(surfaceID: 1) {
                signal.yield(())
                firstRelease.wait()
                return .failed
            }
        }
        let second = Task {
            await coordinator.read(surfaceID: 2) {
                signal.yield(())
                secondRelease.wait()
                return .failed
            }
        }
        var count = 0
        for await _ in started {
            count += 1
            if count == 2 { break }
        }
        defer {
            firstRelease.signal()
            secondRelease.signal()
            signal.finish()
        }
        var events: [String] = []
        #expect(coordinator.deferFree(surfaceID: 1) { events.append("first") })
        #expect(coordinator.deferFree(surfaceID: 2) { events.append("second") })
        #expect(coordinator.deferReload { events.append("reload") })
        firstRelease.signal()
        _ = await first.value
        #expect(events == ["first"])
        secondRelease.signal()
        _ = await second.value
        #expect(events == ["first", "second", "reload"])
    }

}
