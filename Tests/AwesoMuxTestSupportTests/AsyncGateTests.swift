import Testing
@testable import AwesoMuxTestSupport

@MainActor
@Suite("Async gate")
struct AsyncGateTests {
    @Test("open resumes every waiter and stays open")
    func openResumesWaiters() async {
        let gate = AsyncGate()
        let first = Task { @MainActor in await gate.wait() }
        let second = Task { @MainActor in await gate.wait() }

        #expect(await waitUntil { gate.waiterCount == 2 })
        gate.open()
        await first.value
        await second.value
        await gate.wait()
        #expect(gate.waitCallCount == 3)
    }
}
