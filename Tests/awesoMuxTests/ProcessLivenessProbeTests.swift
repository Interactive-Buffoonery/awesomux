import AwesoMuxCore
import Foundation
import Testing
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

    @Test("a zmx daemon samples its direct shell instead of itself")
    func zmxDaemonSamplesDirectShell() {
        let idleSnapshot = [
            ProcEntry(pid: 50, ppid: 1, command: "zmx"),
            ProcEntry(pid: 100, ppid: 50, command: "-zsh"),
        ]
        let busySnapshot =
            idleSnapshot + [
                ProcEntry(pid: 200, ppid: 100, command: "sleep")
            ]

        func liveness(in snapshot: [ProcEntry]) -> ForegroundProcessLiveness {
            ProcessLivenessProbe.bridgedLiveness(
                daemonPID: 50,
                childPIDs: { parent in snapshot.filter { $0.ppid == parent }.map(\.pid) },
                comm: { pid in snapshot.first { $0.pid == pid }?.command }
            )
        }

        #expect(DaemonGCPlan.isIdle(daemonPID: 50, in: idleSnapshot))
        #expect(liveness(in: idleSnapshot) == .bridged)
        #expect(!DaemonGCPlan.isIdle(daemonPID: 50, in: busySnapshot))
        #expect(liveness(in: busySnapshot) == .bridgedBusy)
    }

    @Test("bridged process lookup failures fail closed")
    func bridgedLookupFailuresFailClosed() {
        #expect(
            ProcessLivenessProbe.bridgedLiveness(
                daemonPID: 50,
                childPIDs: { _ in nil },
                comm: { _ in nil }
            ) == .bridgedBusy)
        #expect(
            ProcessLivenessProbe.bridgedLiveness(
                daemonPID: 50,
                childPIDs: { $0 == 50 ? [] : nil },
                comm: { _ in nil }
            ) == .bridged)
        #expect(
            ProcessLivenessProbe.bridgedLiveness(
                daemonPID: 50,
                childPIDs: { $0 == 50 ? [100] : [] },
                comm: { _ in nil }
            ) == .bridgedBusy)
        #expect(
            ProcessLivenessProbe.bridgedLiveness(
                daemonPID: 50,
                childPIDs: { $0 == 50 ? [100] : nil },
                comm: { _ in "zsh" }
            ) == .bridgedBusy)
    }
}
