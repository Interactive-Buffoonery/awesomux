import AwesoMuxTestSupport
import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite("ProcessLivenessProbe")
struct ProcessLivenessProbeTests {

    @Test("daemon incarnation rejects gone and pid-reused processes")
    func daemonIncarnationRequiresMatchingStartTime() {
        let incarnation = AmxDaemonIncarnation(pid: 42, createdAt: 1_700_000_000)

        var sampledPID: pid_t?
        let matching = ProcessLivenessProbe.matchesDaemonIncarnation(incarnation) { pid in
            sampledPID = pid
            return 1_700_000_000_123_456
        }
        #expect(sampledPID == 42)
        #expect(matching)
        #expect(
            !ProcessLivenessProbe.matchesDaemonIncarnation(incarnation) { _ in
                1_700_000_001_000_000
            })
        #expect(!ProcessLivenessProbe.matchesDaemonIncarnation(incarnation) { _ in nil })
    }

    @Test("terminal foreground pid resolves through the sole root shell, same as its comm")
    func terminalForegroundPIDMatchesRootTraversal() {
        let pid = ProcessLivenessProbe.terminalForegroundPID(
            daemonPID: 10,
            childPIDs: { $0 == 10 ? [20] : nil },
            foregroundGroup: { $0 == 20 ? 30 : nil }
        )
        #expect(pid == 30)
        // Not exactly one root child: unresolvable, same guard as the comm path.
        #expect(
            ProcessLivenessProbe.terminalForegroundPID(
                daemonPID: 10,
                childPIDs: { _ in [20, 21] },
                foregroundGroup: { _ in 30 }
            ) == nil
        )
        #expect(
            ProcessLivenessProbe.terminalForegroundPID(
                daemonPID: 10,
                childPIDs: { _ in nil },
                foregroundGroup: { _ in 30 }
            ) == nil
        )
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
        let busySiblingSnapshot =
            idleSnapshot + [
                ProcEntry(pid: 300, ppid: 50, command: "helper")
            ]

        func liveness(in snapshot: [ProcEntry]) -> ForegroundProcessLiveness {
            ProcessLivenessProbe.bridgedLiveness(
                daemonPID: 50,
                childPIDs: { parent in snapshot.filter { $0.ppid == parent }.map(\.pid) },
                comm: { pid in snapshot.first { $0.pid == pid }?.command }
            )
        }

        #expect(liveness(in: idleSnapshot) == .bridged)
        #expect(liveness(in: busySnapshot) == .bridgedBusy)
        #expect(liveness(in: busySiblingSnapshot) == .bridgedBusy)
    }

    @Test("bridged process lookup failures fail closed")
    func bridgedLookupFailuresFailClosed() {
        #expect(
            ProcessLivenessProbe.bridgedLiveness(
                daemonPID: 50,
                childPIDs: { _ in nil },
                comm: { _ in nil }
            ) == .bridgedBusy)
        // Zero daemon children = no root shell was walked; not verified-idle
        // now that `.bridged` closes without confirmation (issue #190).
        #expect(
            ProcessLivenessProbe.bridgedLiveness(
                daemonPID: 50,
                childPIDs: { $0 == 50 ? [] : nil },
                comm: { _ in nil }
            ) == .bridgedIndeterminate)
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
