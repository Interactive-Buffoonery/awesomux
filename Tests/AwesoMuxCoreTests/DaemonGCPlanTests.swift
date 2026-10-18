import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("DaemonGCPlan")
struct DaemonGCPlanTests {
    private let uuidA = "11111111-1111-4111-8111-111111111111"
    private let uuidB = "22222222-2222-4222-8222-222222222222"

    @Test("encoded cwd cannot inject reserved fields or rows")
    func encodedCwdIsFramed() {
        let cwd = "/tmp/x\tclients=0\nname=\(uuidB)"
        let encoded = Data(cwd.utf8).base64EncodedString()
        let raw = "name=\(uuidA)\tpid=100\tclients=2\tcreated=10\tcwd_b64=\(encoded)\tdaemon_pid=99"
        let parsed = DaemonGCPlan.parseAmxList(raw)

        #expect(parsed.count == 1)
        #expect(parsed[0].clients == 2)
        #expect(parsed[0].cwd == cwd)

        let duplicate = "name=\(uuidA)\tpid=100\tclients=2\tclients=0\tcreated=10"
        #expect(DaemonGCPlan.parseAmxList(duplicate).isEmpty)

        for key in ["cmd", "cmd_b64", "ended", "exit_code", "err", "status"] {
            let duplicateLegacyField =
                "name=\(uuidA)\tpid=100\tclients=0\tcreated=10\t\(key)=first\t\(key)=second"
            #expect(DaemonGCPlan.parseAmxList(duplicateLegacyField).isEmpty)
        }
    }

    @Test("amx list: missing/unparseable clients fails safe to in-use (clients=1)")
    func parseListClientsFailSafe() {
        let raw = "  name=\(uuidA)\tpid=100\tcreated=1782263486\tstart_dir=/x"  // no clients field
        let daemons = DaemonGCPlan.parseAmxList(raw)
        #expect(daemons.first?.clients == 1)
    }

    @Test("amx list: absent/zero/malformed daemon_pid reads as unknown without dropping or failing the row")
    func parseListDaemonPIDUnknown() {
        let base = "  name=\(uuidA)\tpid=100\tclients=1\tcreated=500\tstart_dir=/x"
        let rows = [
            base,  // daemon predating the field
            base + "\tdaemon_pid=0",  // zeroed struct from an old daemon
            base + "\tdaemon_pid=1",  // launchd is never a daemon
            base + "\tdaemon_pid=notanint",
            base + "\tdaemon_pid=",
            base + "\tdaemon_pid=-1",
        ]
        for row in rows {
            let parsed = DaemonGCPlan.parseAmxList(row)
            #expect(parsed.count == 1)
            #expect(parsed.first?.daemonPID == nil)
            // Strict must still succeed: aborting the sweep on a missing
            // daemon_pid would abort it on exactly the inherited daemons the
            // field exists to protect.
            #expect(DaemonGCPlan.parseAmxListStrict(row)?.count == 1)
        }
    }

    @Test(arguments: [
        ([ProcEntry(pid: 100, ppid: 50, command: "zsh")], true),
        ([ProcEntry(pid: 100, ppid: 50, command: "-zsh")], true),
        ([ProcEntry(pid: 100, ppid: 50, command: "/bin/zsh")], true),
        ([ProcEntry(pid: 100, ppid: 50, command: "/usr/bin/make")], false),
        ([ProcEntry(pid: 100, ppid: 50, command: "zsh"), ProcEntry(pid: 200, ppid: 100, command: "make")], false),
        ([ProcEntry(pid: 100, ppid: 50, command: "make")], false),
        ([ProcEntry(pid: 999, ppid: 1, command: "zsh")], true),
    ])
    func classifiesDaemonIdle(snapshot: [ProcEntry], expected: Bool) {
        #expect(DaemonGCPlan.isIdle(daemonPID: 50, in: snapshot) == expected)
    }

    @Test("reapable: idle unattached UUID orphan reaped; owned/busy/non-uuid/new/attached spared")
    func reapableMatrix() {
        let orphan = LiveDaemon(id: TerminalSessionID(rawValue: uuidA)!, pid: 100, createdEpoch: 10, clients: 0)
        let owned = LiveDaemon(id: TerminalSessionID(rawValue: uuidB)!, pid: 200, createdEpoch: 10, clients: 0)
        let hand = LiveDaemon(id: TerminalSessionID(rawValue: "dev")!, pid: 300, createdEpoch: 10, clients: 0)
        let busyD = LiveDaemon(
            id: TerminalSessionID(rawValue: "33333333-3333-4333-8333-333333333333")!, pid: 400, createdEpoch: 10, clients: 0)
        let fresh = LiveDaemon(
            id: TerminalSessionID(rawValue: "44444444-4444-4444-8444-444444444444")!, pid: 500, createdEpoch: 99, clients: 0)
        let attached = LiveDaemon(
            id: TerminalSessionID(rawValue: "55555555-5555-4555-8555-555555555555")!, pid: 600, createdEpoch: 10, clients: 1)
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

    @Test(arguments: [500 as Int?, nil])
    func expiresOnlyOverCap(cap: Int?) {
        let expired = LiveDaemon(id: TerminalSessionID(rawValue: uuidA)!, pid: 1, createdEpoch: 0, clients: 0)
        let pinned = LiveDaemon(id: TerminalSessionID(rawValue: uuidB)!, pid: 2, createdEpoch: 0, clients: 0)
        let underCap = LiveDaemon(
            id: TerminalSessionID(rawValue: "33333333-3333-4333-8333-333333333333")!, pid: 3, createdEpoch: 900, clients: 0)
        let live = cap == nil ? [expired] : [expired, pinned, underCap]
        let plan = DaemonGCPlan.expiredReapable(
            live: live, owned: [], busy: [],
            pinned: cap == nil ? [] : [pinned.id],
            idleByID: cap == nil ? [expired.id: true] : [expired.id: true, pinned.id: true, underCap.id: true],
            capThresholdSeconds: cap, now: cap == nil ? 9999 : 1000, gcStart: cap == nil ? 10000 : 1001)
        #expect(plan == (cap == nil ? [] : [expired]))
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

    @Test("status-file sweep spares attached, in-grace, and unparseable files")
    func staleStatusFileSelection() {
        let gcStart = 10_000
        let grace = 3_600
        let attachedID = TerminalSessionID(rawValue: uuidA)!
        let orphanUUID = "33333333-3333-4333-8333-333333333333"
        func candidate(_ uuid: String, token: String = "0a1b2c3d", mtime: Int = 500)
            -> DaemonGCPlan.FileCandidate
        {
            DaemonGCPlan.FileCandidate(
                filename: "\(uuid)-\(token).status.jsonl",
                modifiedEpoch: mtime
            )
        }

        let stale = DaemonGCPlan.staleStatusFiles(
            candidates: [
                candidate(uuidA),  // attached client, however old → spared
                candidate(uuidB),  // stale generation of an unattached session → stale
                candidate(orphanUUID),  // orphan, pre-fence → stale
                candidate(orphanUUID, token: "eeeeeeee", mtime: gcStart - grace),  // exact boundary → spared
                candidate(orphanUUID, token: "ffffffff", mtime: gcStart - 5),  // in-flight attach → spared
                DaemonGCPlan.FileCandidate(
                    filename: "not-a-session.status.jsonl", modifiedEpoch: 1
                ),  // unparseable → spared
                DaemonGCPlan.FileCandidate(filename: "\(uuidB)-0a1b2c3d.status.json", modifiedEpoch: 500),
                DaemonGCPlan.FileCandidate(filename: "\(uuidB).status.jsonl", modifiedEpoch: 500),
                candidate(uuidB, token: "0a1b2c"),
                candidate(uuidB, token: "0A1B2C3D"),
                DaemonGCPlan.FileCandidate(filename: "\(uuidB)_0a1b2c3d.status.jsonl", modifiedEpoch: 500),
                candidate("dev"),
                candidate("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"),
            ],
            attached: [attachedID],
            gcStart: gcStart,
            graceSeconds: grace
        )

        #expect(
            stale.sorted() == [
                "\(uuidB)-0a1b2c3d.status.jsonl",
                "\(orphanUUID)-0a1b2c3d.status.jsonl",
            ])
    }

    @Test("log sweep spares live daemons, in-grace, and unattributable files")
    func staleSessionLogSelection() {
        let gcStart = 10_000
        let grace = 3_600
        let liveID = TerminalSessionID(rawValue: uuidA)!
        let orphanUUID = "33333333-3333-4333-8333-333333333333"
        func candidate(_ name: String, mtime: Int = 500) -> DaemonGCPlan.FileCandidate {
            DaemonGCPlan.FileCandidate(filename: name, modifiedEpoch: mtime)
        }

        let ownedUUID = "77777777-7777-4777-8777-777777777777"
        let ownedID = TerminalSessionID(rawValue: ownedUUID)!
        let stale = DaemonGCPlan.staleSessionLogs(
            candidates: [
                candidate("\(uuidA).log"),  // live daemon, however old → spared
                candidate("\(uuidA).log.old"),  // live daemon's rotated log → spared
                candidate("\(ownedUUID).log"),  // dead but owned (restore may recreate) → spared
                candidate("\(uuidB).log"),  // dead session → stale
                candidate("\(orphanUUID).log.old"),  // dead session's rotated log → stale
                candidate("\(orphanUUID).log", mtime: gcStart - grace),  // exact boundary → spared
                candidate("\(orphanUUID).log", mtime: gcStart - 5),  // in-grace → spared
                candidate("zmx.log"),  // unattributable → spared
                candidate("dev.log"),
                candidate("\(uuidB).log.new"),
                candidate("\(uuidB)-0a1b2c3d.status.jsonl"),
                candidate("\(uuidB)x.log"),
                candidate("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA.log"),
            ],
            liveSessionIDs: [liveID],
            owned: [ownedID],
            gcStart: gcStart,
            graceSeconds: grace
        )

        #expect(
            stale.sorted() == [
                "\(uuidB).log",
                "\(orphanUUID).log.old",
            ])
    }

    private static let cleanList = """
          name=11111111-1111-4111-8111-111111111111\tpid=100\tclients=1\tcreated=500\tstart_dir=/tmp
          name=22222222-2222-4222-8222-222222222222\tpid=200\tclients=0\tcreated=600\tstart_dir=/tmp
        """

    @Test(arguments: [
        (Self.cleanList, 2 as Int?, 2), ("", 0, 0), ("\n \n", 0, 0),
        (Self.cleanList + "\n  session 11111111-1111-4111-8111-111111111111 attached", nil, 2),
        (Self.cleanList + "\n  name=11111111-1111-4111-8111-111111111111\tpid=broken\tcreated=1", nil, 2),
        ("  name=11111111-1111-4111-8111-111111111111\tpid=0\tclients=1\tcreated=500\tstart_dir=/x", nil, 0),
        ("  name=11111111-1111-4111-8111-111111111111\tpid=-1\tclients=1\tcreated=500\tstart_dir=/x", nil, 0),
    ])
    func validatesListRows(raw: String, strictCount: Int?, tolerantCount: Int) {
        #expect(DaemonGCPlan.parseAmxListStrict(raw)?.count == strictCount)
        #expect(DaemonGCPlan.parseAmxList(raw).count == tolerantCount)
    }

    // MARK: - Orphan attach client GC (#183)

    /// `amx list` row for a daemon whose forkpty shell child is `shellPID`.
    private func listedDaemon(shellPID: Int32, daemonPID: Int32? = nil) -> LiveDaemon {
        LiveDaemon(
            id: TerminalSessionID(rawValue: uuidA)!, pid: shellPID, createdEpoch: 10, clients: 1,
            daemonPID: daemonPID)
    }

    @Test(arguments: [
        (false, [ProcEntry]()),
        (false, [ProcEntry(pid: 69207, ppid: 1, command: "-zsh")]),
        (true, []),
    ])
    func unresolvedDaemonPIDAbortsUnion(includeResolvable: Bool, snapshot: [ProcEntry]) {
        var live = [listedDaemon(shellPID: 69207)]
        if includeResolvable {
            live.insert(
                LiveDaemon(
                    id: TerminalSessionID(rawValue: uuidB)!, pid: 100,
                    createdEpoch: 10, clients: 1, daemonPID: 99), at: 0)
        }
        #expect(DaemonGCPlan.liveDaemonPIDs(live: live, snapshot: snapshot) == nil)
    }

    @Test("regression: a daemon inherited from the previous app run is never an orphan-attach candidate")
    func inheritedDaemonIsNeverAnOrphanCandidate() throws {
        // Verified live: `amx list` publishes pid=69207, which is `-zsh`; its
        // parent 69206 is the daemon. The daemon forks without exec'ing, so it
        // still carries its client's `amx attach <uuid>` argv, and its client
        // died with the previous app run, so it is reparented to launchd.
        let listed = listedDaemon(shellPID: 69207)
        let snapshot = [
            ProcEntry(pid: 69206, ppid: 1, command: "/Applications/awesoMux.app/Contents/MacOS/amx"),
            ProcEntry(pid: 69207, ppid: 69206, command: "-zsh"),
        ]
        let daemonPIDs = try #require(DaemonGCPlan.liveDaemonPIDs(live: [listed], snapshot: snapshot))
        #expect(
            DaemonGCPlan.candidateOrphanAttachPIDs(
                snapshot: snapshot, daemonPIDs: daemonPIDs, executableName: "amx"
            ).isEmpty)

        // The shipped bug, pinned: fencing on the listed pids alone selects the
        // daemon itself for SIGTERM.
        #expect(
            DaemonGCPlan.candidateOrphanAttachPIDs(
                snapshot: snapshot, daemonPIDs: Set([listed].map(\.pid)), executableName: "amx"
            ) == [69206])

        // The confirm pass must reach the same verdict from its own inputs.
        let sample = DaemonGCPlan.AttachProcessSample(
            pid: 69206, ppid: 1, etimeSeconds: 7200,
            argv0: "/Applications/awesoMux.app/Contents/MacOS/amx", subcommand: "attach",
            sessionArgument: uuidA)
        #expect(
            DaemonGCPlan.confirmedOrphanAttachSamples(
                samples: [sample], daemonPIDs: daemonPIDs, executableName: "amx",
                localSessionSockets: [uuidA]
            ).map(\.pid).isEmpty)
    }

    @Test(
        "orphan shortlist preserves exclusions and ordering",
        arguments: ["alongsideLiveDaemon", "otherCommand", "parented", "empty", "ordered"])
    func genuineOrphanStillReapedAlongsideLiveDaemon(scenario: String) throws {
        let listed = listedDaemon(shellPID: 69207, daemonPID: 69206)
        let snapshot = [
            ProcEntry(pid: 69206, ppid: 1, command: "amx"),  // live daemon
            ProcEntry(pid: 69207, ppid: 69206, command: "-zsh"),
            ProcEntry(pid: 800, ppid: 1, command: "amx"),  // leaked client (#183)
        ]
        let daemonPIDs = try #require(DaemonGCPlan.liveDaemonPIDs(live: [listed], snapshot: snapshot))
        let candidates: [ProcEntry]
        let expected: [Int32]
        switch scenario {
        case "otherCommand":
            candidates = [ProcEntry(pid: 500, ppid: 1, command: "sleep")]
            expected = []
        case "parented":
            candidates = [ProcEntry(pid: 500, ppid: 42, command: "amx")]
            expected = []
        case "empty":
            candidates = []
            expected = []
        case "ordered":
            candidates = [ProcEntry(pid: 700, ppid: 1, command: "amx"), ProcEntry(pid: 500, ppid: 1, command: "amx")]
            expected = [500, 700]
        default:
            candidates = snapshot
            expected = [800]
        }
        #expect(
            DaemonGCPlan.candidateOrphanAttachPIDs(
                snapshot: candidates, daemonPIDs: daemonPIDs, executableName: "amx") == expected)

        let orphan = DaemonGCPlan.AttachProcessSample(
            pid: 800, ppid: 1, etimeSeconds: 3600, argv0: "amx", subcommand: "attach",
            sessionArgument: uuidB)
        #expect(
            DaemonGCPlan.confirmedOrphanAttachSamples(
                samples: [orphan], daemonPIDs: daemonPIDs, executableName: "amx",
                localSessionSockets: [uuidB]
            ).map(\.pid) == [800])
    }

    @Test("regression INT-914: a sister profile's reattached daemon is never a confirmed orphan, even orphaned and UUID-shaped")
    func crossProfileInheritedDaemonIsNeverConfirmed() {
        // INT-914. A foreign profile's app relaunched and re-attached its
        // sessions minutes earlier, so its daemons keep argv `amx attach
        // <uuid>` while orphaned at ppid == 1 — identical to #183's leaked
        // own-profile client in every process-table fence. `daemonPIDs` cannot
        // spare them: it is built from THIS profile's `amx list` only. Their
        // sockets live in the foreign profile's dir, so absence from
        // `localSessionSockets` is what must spare them.
        let inheritedForeignDaemon = DaemonGCPlan.AttachProcessSample(
            pid: 900, ppid: 1, etimeSeconds: 7200,
            argv0: "/Applications/awesoMux.app/Contents/MacOS/amx", subcommand: "attach",
            sessionArgument: uuidA)
        let orphanedForeignClient = DaemonGCPlan.AttachProcessSample(
            pid: 901, ppid: 1, etimeSeconds: 3600,
            argv0: "/Users/x/dist/awesoMux.app/Contents/MacOS/amx", subcommand: "attach",
            sessionArgument: uuidB)
        #expect(
            DaemonGCPlan.confirmedOrphanAttachSamples(
                samples: [inheritedForeignDaemon, orphanedForeignClient],
                daemonPIDs: [], executableName: "amx",
                localSessionSockets: []
            ).map(\.pid).isEmpty)
    }

    @Test("regression guard INT-914: an own-profile orphan keeps being confirmed when its session socket is local")
    func ownProfileOrphanStillConfirmedAlongsideForeign() {
        // Same inputs as the incident, but the own-profile client's session
        // socket sits in the launching profile's dir — killing it stays the
        // entire point of #183. Only the foreign sibling is spared.
        let ownOrphan = DaemonGCPlan.AttachProcessSample(
            pid: 800, ppid: 1, etimeSeconds: 3600, argv0: "amx", subcommand: "attach",
            sessionArgument: uuidA)
        let foreignOrphan = DaemonGCPlan.AttachProcessSample(
            pid: 900, ppid: 1, etimeSeconds: 3600, argv0: "amx", subcommand: "attach",
            sessionArgument: uuidB)
        #expect(
            DaemonGCPlan.confirmedOrphanAttachSamples(
                samples: [ownOrphan, foreignOrphan], daemonPIDs: [], executableName: "amx",
                localSessionSockets: [uuidA]
            ).map(\.pid) == [800])
    }

    @Test("etime parser: bare seconds, minutes:seconds, hours, and day-prefixed forms")
    func etimeParsing() {
        #expect(DaemonGCPlan.parseEtimeSeconds("00:01") == 1)
        #expect(DaemonGCPlan.parseEtimeSeconds("01:02") == 62)
        #expect(DaemonGCPlan.parseEtimeSeconds("01:02:03") == 3723)
        #expect(DaemonGCPlan.parseEtimeSeconds("05-22:03:16") == 5 * 86400 + 22 * 3600 + 3 * 60 + 16)
        #expect(DaemonGCPlan.parseEtimeSeconds("") == nil)
        #expect(DaemonGCPlan.parseEtimeSeconds("garbage") == nil)
    }

    @Test("attach process sample parser: pid/ppid/etime fixed, args tail preserved with its own spaces")
    func attachProcessSampleParsing() {
        let raw = " 500     1 05-22:03:16 /Applications/awesoMux.app/Contents/MacOS/amx attach \(uuidA)\n"
        let samples = DaemonGCPlan.parseAttachProcessSamples(raw)
        #expect(samples.count == 1)
        #expect(samples[0].pid == 500)
        #expect(samples[0].ppid == 1)
        #expect(samples[0].etimeSeconds == 5 * 86400 + 22 * 3600 + 3 * 60 + 16)
        #expect(samples[0].argv0 == "/Applications/awesoMux.app/Contents/MacOS/amx")
        #expect(samples[0].subcommand == "attach")
        #expect(samples[0].sessionArgument == uuidA)
    }

    @Test(arguments: [
        ("/opt/amx", "attach", "11111111-1111-4111-8111-111111111111" as String?, 1 as Int32, 3600, false, true),
        ("amx", "list", nil, 1, 3600, false, false),
        ("amx", "attach", "11111111-1111-4111-8111-111111111111", 1, 1, false, false),
        ("amx", "attach", "11111111-1111-4111-8111-111111111111", 1, 3600, true, false),
        ("amx", "attach", "11111111-1111-4111-8111-111111111111", 42, 3600, false, false),
        ("amx", "attach", "dev", 1, 3600, false, false),
        ("amx", "attach", nil, 1, 3600, false, false),
    ])
    func confirmsOnlyFencedOrphan(
        argv0: String, subcommand: String, session: String?, parent: Int32, age: Int, knownDaemon: Bool, expected: Bool
    ) {
        let sample = DaemonGCPlan.AttachProcessSample(
            pid: 500, ppid: parent, etimeSeconds: age,
            argv0: argv0, subcommand: subcommand, sessionArgument: session)
        let sockets: Set<String> = subcommand == "attach" ? [session ?? uuidA] : []
        #expect(
            DaemonGCPlan.confirmedOrphanAttachSamples(
                samples: [sample],
                daemonPIDs: knownDaemon ? [500] : [], executableName: "amx", localSessionSockets: sockets
            ).map(\.pid)
                == (expected ? [500] : []))
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
