import Foundation
import Testing

@testable import AwesoMuxTestSupport

@Suite("Bounded process wait (awesomux#207)")
struct ProcessBoundedWaitTests {
    private static func startSleep(_ seconds: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = [seconds]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return process
    }

    @Test("a child that exits normally is waited out and leaves its status readable")
    func normalExitSucceeds() throws {
        let process = try Self.startSleep("0")
        try process.waitUntilExitEventually(deadline: .seconds(30))
        #expect(!process.isRunning)
        // Reading this at all is the point: it raises an uncatchable ObjC
        // exception unless Foundation has actually observed the exit.
        #expect(process.terminationStatus == 0)
    }

    /// Guards the regression that motivated the whole change: the poll must not
    /// depend on the calling thread pumping a run loop, or every wait in the
    /// suite would sit until its deadline.
    @Test("waiting needs no run-loop pumping on the calling thread")
    func exitObservedWithoutRunLoop() throws {
        let process = try Self.startSleep("1")
        let clock = ContinuousClock()
        let start = clock.now
        try process.waitUntilExitEventually(deadline: .seconds(30))
        #expect(clock.now - start < .seconds(10))
        #expect(process.terminationStatus == 0)
    }

    @Test("a live child hits the deadline instead of blocking forever")
    func liveChildTimesOut() throws {
        let process = try Self.startSleep("30")
        defer {
            process.terminate()
            try? process.waitUntilExitEventually(deadline: .seconds(10))
        }
        #expect(throws: ProcessWaitTimeout.self) {
            try process.waitUntilExitEventually(deadline: .milliseconds(200))
        }
        // The helper must leave the child alone — signalling a possibly-recycled
        // PID after a stale reading is exactly what it refuses to do.
        #expect(process.isRunning)
    }

    /// The actual #207 state: the child is gone but Foundation's view is stuck
    /// `true` forever. A dropped termination event cannot be provoked on demand,
    /// so drive the deadline loop's liveness seam directly.
    @Test("a permanently-stuck liveness reading still terminates the wait")
    func stuckLivenessStillBounded() throws {
        let clock = ContinuousClock()
        let start = clock.now
        #expect(throws: ProcessWaitTimeout.self) {
            try waitForExit(deadline: .milliseconds(200)) { true }
        }
        #expect(clock.now - start < .seconds(5))
    }

    @Test("an already-exited process returns without polling")
    func alreadyExitedReturnsImmediately() throws {
        let process = try Self.startSleep("0")
        try process.waitUntilExitEventually(deadline: .seconds(30))
        try process.waitUntilExitEventually(deadline: .zero)
    }
}
