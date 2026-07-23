import Foundation
import Testing
@testable import awesoMux

@Suite("Ghostty wakeup coalescer")
struct GhosttyWakeupCoalescerTests {
    @Test("schedule stamps the pending wakeup and clearPending clears it")
    func scheduleStampsPendingWakeup() {
        let coalescer = GhosttyWakeupCoalescer()
        #expect(coalescer.pendingWakeupAge == nil)

        coalescer.schedule {}
        #expect(coalescer.pendingWakeupAge != nil)

        coalescer.clearPending()
        #expect(coalescer.pendingWakeupAge == nil)
    }

    @Test("a dropped wakeup does not refresh the pending age")
    func droppedWakeupKeepsOldestStamp() {
        let coalescer = GhosttyWakeupCoalescer()
        var operationRuns = 0

        coalescer.schedule { operationRuns += 1 }
        let firstAge = coalescer.pendingWakeupAge
        coalescer.schedule { operationRuns += 1 }
        let ageAfterDrop = coalescer.pendingWakeupAge

        #expect(operationRuns == 1)
        // Age keeps growing from the ORIGINAL stamp; a dropped wakeup
        // must not reset it to zero.
        #expect(firstAge != nil)
        #expect(ageAfterDrop != nil)
        #expect(ageAfterDrop! >= firstAge!)
    }

    @Test("clearPending re-arms the latch for the next wakeup")
    func clearPendingReArms() {
        let coalescer = GhosttyWakeupCoalescer()
        var operationRuns = 0

        coalescer.schedule { operationRuns += 1 }
        coalescer.clearPending()
        coalescer.schedule { operationRuns += 1 }

        #expect(operationRuns == 2)
        #expect(coalescer.pendingWakeupAge != nil)
    }
}
