import Testing
@testable import AwesoMuxTestSupport

@Suite("Event recorder")
struct EventRecorderTests {
    @Test("records events in order and waits with a bound")
    func recordsInOrder() async {
        let recorder = EventRecorder<String>()
        Task {
            await Task.yield()
            await recorder.record("first")
            await recorder.record("second")
        }

        #expect(await recorder.waitForCount(2))
        #expect(await recorder.values == ["first", "second"])
        #expect(!(await recorder.waitForCount(3, attempts: 1)))
    }
}
