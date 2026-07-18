import AwesoMuxTestSupport
import Dispatch
import Foundation
import Testing
@testable import awesoMux

@Suite("Ghostty fault log source")
struct GhosttyFaultLogSourceTests {
    @Test("OSLog source satisfies the asynchronous fault-source interface")
    func conformsToFaultSourceInterface() {
        let source: any GhosttyFaultLogSource = OSLogGhosttyFaultSource()
        _ = source
    }

    @MainActor
    @Test("synchronous fault queries run off the main actor")
    func synchronousQueryRunsOffMainActor() async {
        let release = DispatchSemaphore(value: 0)
        let observation = ThreadObservation()
        let source = OSLogGhosttyFaultSource { _, _, _ in
            observation.record(isMainThread: Thread.isMainThread)
            release.wait()
            return 0
        }

        let query = Task { @MainActor in
            await source.recentFaultCount(
                subsystem: "com.mitchellh.ghostty",
                category: "libxev_kqueue",
                since: .distantPast
            )
        }
        #expect(await waitUntil { observation.isMainThread != nil })

        var mainActorWorkRan = false
        Task { @MainActor in mainActorWorkRan = true }
        #expect(await waitUntil { mainActorWorkRan })
        #expect(observation.isMainThread == false)

        release.signal()
        #expect(await query.value == 0)
    }

    @MainActor
    @Test("a cancelled query does not admit a replacement until its worker exits")
    func cancelledQueryKeepsAdmissionUntilWorkerExits() async {
        let release = DispatchSemaphore(value: 0)
        let observation = QueryObservation()
        let source = OSLogGhosttyFaultSource { _, _, _ in
            let invocation = observation.begin()
            if invocation == 1 { release.wait() }
            return invocation
        }

        let first = Task { @MainActor in
            await source.recentFaultCount(
                subsystem: "com.mitchellh.ghostty",
                category: "libxev_kqueue",
                since: .distantPast
            )
        }
        #expect(await waitUntil { observation.started == 1 })
        first.cancel()
        #expect(await first.value == 0)

        let rejected = await source.recentFaultCount(
            subsystem: "com.mitchellh.ghostty",
            category: "libxev_kqueue",
            since: .distantPast
        )
        #expect(rejected == 0)
        #expect(observation.started == 1)

        release.signal()
        #expect(
            await waitUntilAsync {
                await source.recentFaultCount(
                    subsystem: "com.mitchellh.ghostty",
                    category: "libxev_kqueue",
                    since: .distantPast
                ) == 2
            })
    }
}

private final class ThreadObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storedIsMainThread: Bool?

    func record(isMainThread: Bool) {
        lock.withLock { storedIsMainThread = isMainThread }
    }

    var isMainThread: Bool? {
        lock.withLock { storedIsMainThread }
    }
}

private final class QueryObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var startedCount = 0

    func begin() -> Int {
        lock.withLock {
            startedCount += 1
            return startedCount
        }
    }

    var started: Int {
        lock.withLock { startedCount }
    }
}
