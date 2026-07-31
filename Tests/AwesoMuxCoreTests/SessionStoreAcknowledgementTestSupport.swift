import AwesoMuxTestSupport
@testable import AwesoMuxCore

@MainActor
extension SessionStore {
    func controlAcknowledgementDwell() -> TestScheduler {
        let scheduler = TestScheduler()
        acknowledgementCoordinator.delay = { nanoseconds in
            await scheduler.wait(for: .nanoseconds(Int64(clamping: nanoseconds)))
            try Task.checkCancellation()
        }
        return scheduler
    }
}
