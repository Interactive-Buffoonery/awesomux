import Testing
@testable import awesoMux

@MainActor
@Suite("GhosttyRuntime event loop watchdog wiring")
struct GhosttyRuntimeEventLoopWatchdogWiringTests {
    @Test("tick() records a heartbeat on the watchdog")
    func tickRecordsHeartbeat() {
        let runtime = GhosttyRuntime()
        defer { runtime.discardAllSurfaces() }
        let before = runtime.lastEventLoopTickAtForTesting
        runtime.tick()
        #expect(runtime.lastEventLoopTickAtForTesting > before)
    }
}
