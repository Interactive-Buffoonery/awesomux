import Testing
@testable import AwesoMuxTestSupport

@MainActor
@Suite("Bounded waits")
struct WaitTests {
    @Test("main actor wait succeeds after a yielded update")
    func mainActorWaitSucceeds() async {
        var ready = false
        Task { @MainActor in
            await Task.yield()
            ready = true
        }

        #expect(await waitUntil { ready })
        #expect(!(await waitUntil(attempts: 1) { false }))
    }

    @Test("async wait observes actor state")
    func asyncWaitSucceeds() async {
        let recorder = EventRecorder<Int>()
        async let observed = waitUntilAsync { await recorder.values.count == 1 }
        await recorder.record(1)

        #expect(await observed)
    }
}
