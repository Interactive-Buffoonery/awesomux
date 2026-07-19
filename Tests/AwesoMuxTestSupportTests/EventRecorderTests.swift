import Dispatch
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

    @Test("waits for real-time-delayed events with a deadline")
    func waitsWithDeadline() async {
        let recorder = EventRecorder<String>()
        Task {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(30)) {
                    continuation.resume()
                }
            }
            await recorder.record("event")
        }

        #expect(await recorder.waitForCount(1, deadline: .seconds(10)))
        #expect(!(await recorder.waitForCount(2, deadline: .milliseconds(20))))
    }
}
