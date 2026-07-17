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
