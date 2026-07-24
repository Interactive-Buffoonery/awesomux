import AwesoMuxBridgeProtocol
import Foundation
import Testing
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
        #expect(!DaemonGCPlan.isUUIDShaped("11111111-1111-4111-8111-11111111111"))  // short
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
        let raw = "  name=\(uuidA)\tpid=100\tcreated=1782263486\tstart_dir=/x"  // no clients field
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
        let snapshot = [ProcEntry(pid: 100, ppid: 50, command: "zsh")]  // daemon 50 -> shell 100
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
            ProcEntry(pid: 200, ppid: 100, command: "make"),
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

    @Test("expiredReapable: idle unpinned over-cap orphan reaped; pinned/busy/under-cap spared")
    func expiredReapableMatrix() {
        let expired = LiveDaemon(id: TerminalSessionID(rawValue: uuidA)!, pid: 1, createdEpoch: 0, clients: 0)
        let pinned = LiveDaemon(id: TerminalSessionID(rawValue: uuidB)!, pid: 2, createdEpoch: 0, clients: 0)
        let underCap = LiveDaemon(
            id: TerminalSessionID(rawValue: "33333333-3333-4333-8333-333333333333")!, pid: 3, createdEpoch: 900, clients: 0)
        let plan = DaemonGCPlan.expiredReapable(
            live: [expired, pinned, underCap],
            owned: [], busy: [],
            pinned: [pinned.id],
            idleByID: [expired.id: true, pinned.id: true, underCap.id: true],
            capThresholdSeconds: 500, now: 1000, gcStart: 1001
        )
        #expect(plan == [expired])  // age 1000≥500 idle unpinned; pinned spared; underCap age 100<500 spared
    }

    @Test("expiredReapable: cap nil reaps nothing")
    func expiredReapableCapOff() {
        let orphan = LiveDaemon(id: TerminalSessionID(rawValue: uuidA)!, pid: 1, createdEpoch: 0, clients: 0)
        #expect(
            DaemonGCPlan.expiredReapable(
                live: [orphan], owned: [], busy: [], pinned: [], idleByID: [orphan.id: true],
                capThresholdSeconds: nil, now: 9999, gcStart: 10000
            ).isEmpty)
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

    @Test("status filename parser accepts minted names only")
    func statusFilenameParsing() {
        let minted = "\(uuidA)-0a1b2c3d.status.jsonl"
        #expect(DaemonGCPlan.statusFileSessionID(minted)?.rawValue == uuidA)

        #expect(DaemonGCPlan.statusFileSessionID("\(uuidA)-0a1b2c3d.status.json") == nil)  // wrong suffix
        #expect(DaemonGCPlan.statusFileSessionID("\(uuidA).status.jsonl") == nil)  // no token
        #expect(DaemonGCPlan.statusFileSessionID("\(uuidA)-0a1b2c.status.jsonl") == nil)  // short token
        #expect(DaemonGCPlan.statusFileSessionID("\(uuidA)-0A1B2C3D.status.jsonl") == nil)  // uppercase token
        #expect(DaemonGCPlan.statusFileSessionID("\(uuidA)_0a1b2c3d.status.jsonl") == nil)  // wrong separator
        #expect(DaemonGCPlan.statusFileSessionID("dev-0a1b2c3d.status.jsonl") == nil)  // hand name
        #expect(
            DaemonGCPlan.statusFileSessionID(
                "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA-0a1b2c3d.status.jsonl") == nil)  // uppercase uuid
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

    @Test("log filename parser accepts <uuid>.log and rotated .log.old only")
    func logFilenameParsing() {
        #expect(DaemonGCPlan.logFileSessionID("\(uuidA).log")?.rawValue == uuidA)
        #expect(DaemonGCPlan.logFileSessionID("\(uuidA).log.old")?.rawValue == uuidA)

        #expect(DaemonGCPlan.logFileSessionID("zmx.log") == nil)  // global log, non-UUID stem
        #expect(DaemonGCPlan.logFileSessionID("dev.log") == nil)  // hand name
        #expect(DaemonGCPlan.logFileSessionID("\(uuidA).log.new") == nil)  // unknown rotation suffix
        #expect(DaemonGCPlan.logFileSessionID("\(uuidA)-0a1b2c3d.status.jsonl") == nil)  // status file
        #expect(DaemonGCPlan.logFileSessionID("\(uuidA)x.log") == nil)  // stem too long
        #expect(
            DaemonGCPlan.logFileSessionID(
                "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA.log") == nil)  // uppercase uuid
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

    @Test("attach-gate spared count measures only aged, attributed, attached files")
    func attachGateSpared() {
        let gcStart = 10_000
        let grace = 3_600
        let idA = TerminalSessionID(rawValue: uuidA)!
        let idB = TerminalSessionID(rawValue: uuidB)!
        func candidate(_ uuid: String, token: String, mtime: Int = 500)
            -> DaemonGCPlan.FileCandidate
        {
            DaemonGCPlan.FileCandidate(
                filename: "\(uuid)-\(token).status.jsonl", modifiedEpoch: mtime)
        }

        let spared = DaemonGCPlan.attachGateSparedStatusFiles(
            candidates: [
                candidate(uuidA, token: "00000001"),  // attached + aged → counted
                candidate(uuidA, token: "00000002"),  // attached + aged, same session → counted
                candidate(uuidB, token: "00000003"),  // attached + aged, other session → counted
                candidate(uuidA, token: "00000004", mtime: gcStart - 5),  // in-grace → not counted
                candidate("33333333-3333-4333-8333-333333333333", token: "00000005"),  // unattached → not counted
                DaemonGCPlan.FileCandidate(filename: "junk.status.jsonl", modifiedEpoch: 1),  // unattributable
            ],
            attached: [idA, idB],
            gcStart: gcStart,
            graceSeconds: grace
        )
        #expect(spared.files == 3)
        #expect(spared.sessions == 2)

        // Nothing attached → a real zero observation.
        let none = DaemonGCPlan.attachGateSparedStatusFiles(
            candidates: [candidate(uuidA, token: "00000006")],
            attached: [],
            gcStart: gcStart,
            graceSeconds: grace
        )
        #expect(none.files == 0)
        #expect(none.sessions == 0)
    }

    @Test("strict list parse rejects any nonblank row the tolerant parser skips")
    func strictListParse() {
        let clean = """
              name=\(uuidA)\tpid=100\tclients=1\tcreated=500\tstart_dir=/tmp
              name=\(uuidB)\tpid=200\tclients=0\tcreated=600\tstart_dir=/tmp
            """
        #expect(DaemonGCPlan.parseAmxListStrict(clean)?.count == 2)
        #expect(DaemonGCPlan.parseAmxListStrict("")?.isEmpty == true)
        #expect(DaemonGCPlan.parseAmxListStrict("\n \n")?.isEmpty == true)

        let drifted = clean + "\n  session \(uuidA) attached"
        #expect(DaemonGCPlan.parseAmxList(drifted).count == 2)  // tolerant skips
        #expect(DaemonGCPlan.parseAmxListStrict(drifted) == nil)  // strict aborts

        let malformedRow = clean + "\n  name=\(uuidA)\tpid=broken\tcreated=1"
        #expect(DaemonGCPlan.parseAmxListStrict(malformedRow) == nil)
    }

    // MARK: - Orphan attach client GC (#183)

    @Test("candidate shortlist: orphaned amx process detected, basename-normalized")
    func candidateOrphanDetected() {
        let snapshot = [ProcEntry(pid: 500, ppid: 1, command: "/Applications/awesoMux.app/Contents/MacOS/amx")]
        #expect(
            DaemonGCPlan.candidateOrphanAttachPIDs(snapshot: snapshot, daemonPIDs: [], executableName: "amx")
                == [500])
    }

    @Test("candidate shortlist: known daemon pid excluded even when ppid == 1")
    func candidateOrphanExcludesDaemon() {
        let snapshot = [ProcEntry(pid: 500, ppid: 1, command: "amx")]
        #expect(
            DaemonGCPlan.candidateOrphanAttachPIDs(snapshot: snapshot, daemonPIDs: [500], executableName: "amx")
                .isEmpty)
    }

    @Test("candidate shortlist: non-matching command ignored")
    func candidateOrphanIgnoresOtherCommands() {
        let snapshot = [ProcEntry(pid: 500, ppid: 1, command: "sleep")]
        #expect(
            DaemonGCPlan.candidateOrphanAttachPIDs(snapshot: snapshot, daemonPIDs: [], executableName: "amx")
                .isEmpty)
    }

    @Test("candidate shortlist: still-parented process not flagged")
    func candidateOrphanIgnoresParented() {
        let snapshot = [ProcEntry(pid: 500, ppid: 42, command: "amx")]
        #expect(
            DaemonGCPlan.candidateOrphanAttachPIDs(snapshot: snapshot, daemonPIDs: [], executableName: "amx")
                .isEmpty)
    }

    @Test("candidate shortlist: empty snapshot yields empty result, deterministic ascending order")
    func candidateOrphanEmptyAndOrdered() {
        #expect(DaemonGCPlan.candidateOrphanAttachPIDs(snapshot: [], daemonPIDs: [], executableName: "amx").isEmpty)
        let snapshot = [
            ProcEntry(pid: 700, ppid: 1, command: "amx"),
            ProcEntry(pid: 500, ppid: 1, command: "amx"),
        ]
        #expect(
            DaemonGCPlan.candidateOrphanAttachPIDs(snapshot: snapshot, daemonPIDs: [], executableName: "amx")
                == [500, 700])
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

    @Test("attach process sample parser: no subcommand token still parses argv0")
    func attachProcessSampleParsingNoSubcommand() {
        let raw = " 500     1 00:05 amx\n"
        let samples = DaemonGCPlan.parseAttachProcessSamples(raw)
        #expect(samples.count == 1)
        #expect(samples[0].argv0 == "amx")
        #expect(samples[0].subcommand == nil)
        #expect(samples[0].sessionArgument == nil)
    }

    @Test("attach process sample parser: malformed lines dropped, not crashed on")
    func attachProcessSampleParsingMalformed() {
        #expect(DaemonGCPlan.parseAttachProcessSamples("garbage\n").isEmpty)
        #expect(DaemonGCPlan.parseAttachProcessSamples("500 notanint 00:05 amx attach x\n").isEmpty)
        #expect(DaemonGCPlan.parseAttachProcessSamples("").isEmpty)
    }

    @Test("confirmed orphans: attach subcommand, old enough, unowned daemon pid, UUID session all required")
    func confirmedOrphanRequiresEveryFence() {
        let old = DaemonGCPlan.AttachProcessSample(
            pid: 500, ppid: 1, etimeSeconds: 3600, argv0: "/opt/amx", subcommand: "attach",
            sessionArgument: uuidA)
        #expect(
            DaemonGCPlan.confirmedOrphanAttachPIDs(samples: [old], daemonPIDs: [], executableName: "amx") == [500])
    }

    @Test("confirmed orphans: list/kill/send/history one-shots never match, regardless of age")
    func confirmedOrphanExcludesOtherSubcommands() {
        let oneShot = DaemonGCPlan.AttachProcessSample(
            pid: 500, ppid: 1, etimeSeconds: 3600, argv0: "amx", subcommand: "list", sessionArgument: nil)
        #expect(
            DaemonGCPlan.confirmedOrphanAttachPIDs(samples: [oneShot], daemonPIDs: [], executableName: "amx")
                .isEmpty)
    }

    @Test("confirmed orphans: too young to rule out a daemon mid-startup is excluded")
    func confirmedOrphanExcludesTooYoung() {
        let justStarted = DaemonGCPlan.AttachProcessSample(
            pid: 500, ppid: 1, etimeSeconds: 1, argv0: "amx", subcommand: "attach", sessionArgument: uuidA)
        #expect(
            DaemonGCPlan.confirmedOrphanAttachPIDs(samples: [justStarted], daemonPIDs: [], executableName: "amx")
                .isEmpty)
    }

    @Test("confirmed orphans: still-a-daemon pid excluded even if superficially orphan-shaped")
    func confirmedOrphanExcludesDaemonPID() {
        let sample = DaemonGCPlan.AttachProcessSample(
            pid: 500, ppid: 1, etimeSeconds: 3600, argv0: "amx", subcommand: "attach", sessionArgument: uuidA)
        #expect(
            DaemonGCPlan.confirmedOrphanAttachPIDs(samples: [sample], daemonPIDs: [500], executableName: "amx")
                .isEmpty)
    }

    @Test("confirmed orphans: reparented mid-list (ppid != 1) excluded")
    func confirmedOrphanExcludesStillParented() {
        let sample = DaemonGCPlan.AttachProcessSample(
            pid: 500, ppid: 42, etimeSeconds: 3600, argv0: "amx", subcommand: "attach", sessionArgument: uuidA)
        #expect(
            DaemonGCPlan.confirmedOrphanAttachPIDs(samples: [sample], daemonPIDs: [], executableName: "amx")
                .isEmpty)
    }

    @Test("confirmed orphans: hand-run session name (non-UUID) is never a candidate, mirroring reapable()")
    func confirmedOrphanExcludesHandNamedSession() {
        let sample = DaemonGCPlan.AttachProcessSample(
            pid: 500, ppid: 1, etimeSeconds: 3600, argv0: "amx", subcommand: "attach", sessionArgument: "dev")
        #expect(
            DaemonGCPlan.confirmedOrphanAttachPIDs(samples: [sample], daemonPIDs: [], executableName: "amx")
                .isEmpty)
    }

    @Test("confirmed orphans: missing session argument is never a candidate")
    func confirmedOrphanExcludesMissingSessionArgument() {
        let sample = DaemonGCPlan.AttachProcessSample(
            pid: 500, ppid: 1, etimeSeconds: 3600, argv0: "amx", subcommand: "attach", sessionArgument: nil)
        #expect(
            DaemonGCPlan.confirmedOrphanAttachPIDs(samples: [sample], daemonPIDs: [], executableName: "amx")
                .isEmpty)
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
