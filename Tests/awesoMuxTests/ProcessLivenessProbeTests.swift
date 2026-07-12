import Testing
import Foundation
@testable import awesoMux

@Suite("ProcessLivenessProbe")
struct ProcessLivenessProbeTests {
    @Test("a reaped/gone pid reports nil children, not false")
    func goneParentIsNil() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["0"]
        try p.run()
        p.waitUntilExit()              // process exits AND is reaped → pid invalid
        #expect(ProcessLivenessProbe.hasChildren(pid: p.processIdentifier) == nil)
    }

    @Test("a live process with no children reports false")
    func liveChildlessIsFalse() throws {
        // A `sleep` is alive with no children of its own, so this deterministically
        // exercises the false path (vs nil for a gone parent, vs true for a busy one)
        // without depending on the test runner's ambient children.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        defer { p.terminate() }
        #expect(ProcessLivenessProbe.foregroundComm(pid: p.processIdentifier) != nil)
        #expect(ProcessLivenessProbe.hasChildren(pid: p.processIdentifier) == false)
    }
}
