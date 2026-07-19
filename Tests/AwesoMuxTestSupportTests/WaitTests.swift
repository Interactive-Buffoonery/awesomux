import Dispatch
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

    @Test("eventual wait observes a real-time-delayed update")
    func eventualWaitSucceeds() async {
        var ready = false
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) {
            ready = true
        }

        #expect(
            await waitUntilEventually(
                deadline: .seconds(10),
                pollEvery: .milliseconds(5)
            ) { ready }
        )
        #expect(
            !(await waitUntilEventually(
                deadline: .milliseconds(20),
                pollEvery: .milliseconds(5)
            ) { false })
        )
    }
}
