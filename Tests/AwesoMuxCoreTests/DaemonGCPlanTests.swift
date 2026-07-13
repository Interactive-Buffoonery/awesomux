import Testing
import Foundation
@testable import AwesoMuxCore

@Suite("DaemonGCPlan")
struct DaemonGCPlanTests {
    private let uuidA = "11111111-1111-4111-8111-111111111111"
    private let uuidB = "22222222-2222-4222-8222-222222222222"

    @Test("UUID-shape gate accepts minted ids, rejects hand names")
    func uuidShape() {
        #expect(DaemonGCPlan.isUUIDShaped(uuidA))
        #expect(DaemonGCPlan.isUUIDShaped(TerminalSessionID.generate().rawValue))
        #expect(!DaemonGCPlan.isUUIDShaped("dev"))
        #expect(!DaemonGCPlan.isUUIDShaped("11111111-1111-4111-8111-11111111111"))   // short
        #expect(!DaemonGCPlan.isUUIDShaped("ABCDEFAB-1111-4111-8111-111111111111"))  // uppercase rejected
    }

    @Test("amx list parser extracts id/pid/created, skips junk")
    func parseList() {
        let raw = """
          name=\(uuidA)\tpid=100\tclients=0\tcreated=1782263486\tstart_dir=/x
          name=\(uuidB)\tpid=200\tclients=1\tcreated=1782263487\tstart_dir=/a b\tended=1782263490\texit_code=0
          name=dev\tpid=300\tclients=0\tcreated=1782263488\tstart_dir=/y
          garbage line
          name=\(uuidA)\tpid=notanint\tcreated=1782263486
        """
        let daemons = DaemonGCPlan.parseAmxList(raw)
        #expect(daemons.contains(LiveDaemon(id: TerminalSessionID(rawValue: uuidA)!, pid: 100, createdEpoch: 1782263486, clients: 0)))
        #expect(daemons.contains(LiveDaemon(id: TerminalSessionID(rawValue: uuidB)!, pid: 200, createdEpoch: 1782263487, clients: 1)))
        // "dev" is a valid TerminalSessionID (not UUID), still parsed; the UUID gate applies later.
        #expect(daemons.contains { $0.id.rawValue == "dev" })
        // unparseable pid drops that row entirely (the good uuidA row already parsed).
        #expect(daemons.filter { $0.id.rawValue == uuidA }.count == 1)
    }

    @Test("amx list: missing/unparseable clients fails safe to in-use (clients=1)")
    func parseListClientsFailSafe() {
        let raw = "  name=\(uuidA)\tpid=100\tcreated=1782263486\tstart_dir=/x"   // no clients field
        let daemons = DaemonGCPlan.parseAmxList(raw)
        #expect(daemons.first?.clients == 1)
    }

    @Test("process snapshot parser")
    func parseProcs() {
        let raw = " 100 1 zsh\n 200 100 sleep\n 300 1 -bash\nbad\n"
        let procs = DaemonGCPlan.parseProcessSnapshot(raw)
        #expect(procs.contains(ProcEntry(pid: 100, ppid: 1, command: "zsh")))
        #expect(procs.contains(ProcEntry(pid: 200, ppid: 100, command: "sleep")))
        #expect(procs.contains(ProcEntry(pid: 300, ppid: 1, command: "-bash")))
        #expect(procs.count == 3)
    }

    @Test("idle: daemon -> shell -> no children")
    func idleShell() {
        let snapshot = [ProcEntry(pid: 100, ppid: 50, command: "zsh")]   // daemon 50 -> shell 100
        #expect(DaemonGCPlan.isIdle(daemonPID: 50, in: snapshot))
    }

    @Test("idle: login shell argv0 (-zsh) still recognized")
    func idleLoginShell() {
        let snapshot = [ProcEntry(pid: 100, ppid: 50, command: "-zsh")]
        #expect(DaemonGCPlan.isIdle(daemonPID: 50, in: snapshot))
    }

    @Test("idle: macOS ps comm= gives full path, basename still recognized")
    func idleFullPathShell() {
        // `ps -axo comm=` returns the executable path, e.g. "/bin/zsh".
        let snapshot = [ProcEntry(pid: 100, ppid: 50, command: "/bin/zsh")]
        #expect(DaemonGCPlan.isIdle(daemonPID: 50, in: snapshot))
    }

    @Test("busy: full-path non-shell child is live work")
    func busyFullPathExec() {
        let snapshot = [ProcEntry(pid: 100, ppid: 50, command: "/usr/bin/make")]
        #expect(!DaemonGCPlan.isIdle(daemonPID: 50, in: snapshot))
    }

    @Test("busy: shell has a foreground child")
    func busyForeground() {
        let snapshot = [
            ProcEntry(pid: 100, ppid: 50, command: "zsh"),
            ProcEntry(pid: 200, ppid: 100, command: "make")
        ]
        #expect(!DaemonGCPlan.isIdle(daemonPID: 50, in: snapshot))
    }

    @Test("busy: daemon child is not a shell (exec replaced it)")
    func busyExec() {
        let snapshot = [ProcEntry(pid: 100, ppid: 50, command: "make")]
        #expect(!DaemonGCPlan.isIdle(daemonPID: 50, in: snapshot))
    }

    @Test("idle: daemon with no children at all")
    func idleNoChildren() {
        #expect(DaemonGCPlan.isIdle(daemonPID: 50, in: [ProcEntry(pid: 999, ppid: 1, command: "zsh")]))
    }

    @Test("reapable: idle unattached UUID orphan reaped; owned/busy/non-uuid/new/attached spared")
    func reapableMatrix() {
        let orphan   = LiveDaemon(id: TerminalSessionID(rawValue: uuidA)!, pid: 100, createdEpoch: 10, clients: 0)
        let owned    = LiveDaemon(id: TerminalSessionID(rawValue: uuidB)!, pid: 200, createdEpoch: 10, clients: 0)
        let hand     = LiveDaemon(id: TerminalSessionID(rawValue: "dev")!, pid: 300, createdEpoch: 10, clients: 0)
        let busyD    = LiveDaemon(id: TerminalSessionID(rawValue: "33333333-3333-4333-8333-333333333333")!, pid: 400, createdEpoch: 10, clients: 0)
        let fresh    = LiveDaemon(id: TerminalSessionID(rawValue: "44444444-4444-4444-8444-444444444444")!, pid: 500, createdEpoch: 99, clients: 0)
        let attached = LiveDaemon(id: TerminalSessionID(rawValue: "55555555-5555-4555-8555-555555555555")!, pid: 600, createdEpoch: 10, clients: 1)
        let plan = DaemonGCPlan.reapable(
            live: [orphan, owned, hand, busyD, fresh, attached],
            owned: [owned.id],
            busy: [busyD.id],
            gcStart: 50
        )
        #expect(plan == [orphan])
    }

    @Test("reapable: created == gcStart is spared (the safety boundary)")
    func reapableSameSecondBoundary() {
        let sameSecond = LiveDaemon(id: TerminalSessionID(rawValue: uuidA)!, pid: 100, createdEpoch: 50, clients: 0)
        let plan = DaemonGCPlan.reapable(live: [sameSecond], owned: [], busy: [], gcStart: 50)
        #expect(plan.isEmpty)
    }

    @Test("expiredReapable: idle unpinned over-cap orphan reaped; pinned/busy/under-cap spared")
    func expiredReapableMatrix() {
        let expired = LiveDaemon(id: TerminalSessionID(rawValue: uuidA)!, pid: 1, createdEpoch: 0, clients: 0)
        let pinned  = LiveDaemon(id: TerminalSessionID(rawValue: uuidB)!, pid: 2, createdEpoch: 0, clients: 0)
        let underCap = LiveDaemon(id: TerminalSessionID(rawValue: "33333333-3333-4333-8333-333333333333")!, pid: 3, createdEpoch: 900, clients: 0)
        let plan = DaemonGCPlan.expiredReapable(
            live: [expired, pinned, underCap],
            owned: [], busy: [],
            pinned: [pinned.id],
            idleByID: [expired.id: true, pinned.id: true, underCap.id: true],
            capThresholdSeconds: 500, now: 1000, gcStart: 1001
        )
        #expect(plan == [expired])   // age 1000≥500 idle unpinned; pinned spared; underCap age 100<500 spared
    }

    @Test("expiredReapable: cap nil reaps nothing")
    func expiredReapableCapOff() {
        let orphan = LiveDaemon(id: TerminalSessionID(rawValue: uuidA)!, pid: 1, createdEpoch: 0, clients: 0)
        #expect(DaemonGCPlan.expiredReapable(
            live: [orphan], owned: [], busy: [], pinned: [], idleByID: [orphan.id: true],
            capThresholdSeconds: nil, now: 9999, gcStart: 10000).isEmpty)
    }

    @Test("reachability splits live-pane ids from restorable-only ids")
    func reachabilitySplit() {
        let live = TerminalSessionID(rawValue: uuidA)!
        let closed = TerminalSessionID(rawValue: uuidB)!
        let both = TerminalSessionID(rawValue: "55555555-5555-4555-8555-555555555555")!
        let result = DaemonGCPlan.reachability(
            groups: [Self.group(sessionID: live), Self.group(sessionID: both)],
            recentlyClosed: [Self.closed(sessionID: closed), Self.closed(sessionID: both)],
            lastClosedTransient: nil
        )
        #expect(result.livePane == [live, both])
        // `both` is live, so it must NOT also appear as restorable (disjoint sets).
        #expect(result.restorable == [closed])
    }

    @Test("reachableSessionIDs unions layout, recentlyClosed, lastClosedTransient")
    func reachable() {
        let a = TerminalSessionID(rawValue: uuidA)!
        let b = TerminalSessionID(rawValue: uuidB)!
        let c = TerminalSessionID(rawValue: "55555555-5555-4555-8555-555555555555")!
        let ids = DaemonGCPlan.reachableSessionIDs(
            groups: [Self.group(sessionID: a)],
            recentlyClosed: [Self.closed(sessionID: b)],
            lastClosedTransient: Self.closed(sessionID: c)
        )
        #expect(ids == [a, b, c])
    }

    // MARK: - Test factories

    private static func pane(_ sessionID: TerminalSessionID) -> TerminalPane {
        var pane = TerminalPane(title: "t", workingDirectory: "/tmp", executionPlan: .local)
        pane.terminalSessionID = sessionID
        return pane
    }

    private static func group(sessionID: TerminalSessionID) -> SessionGroup {
        SessionGroup(
            name: "g",
            sessions: [TerminalSession(title: "ws", workingDirectory: "~", layout: .pane(pane(sessionID)))]
        )
    }

    private static func closed(sessionID: TerminalSessionID) -> RecentlyClosedWorkspace {
        let pane = pane(sessionID)
        return RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "ws",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .pane(pane),
            activePaneID: pane.id,
            groupID: UUID(),
            groupName: "g",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date()
        )
    }
}
