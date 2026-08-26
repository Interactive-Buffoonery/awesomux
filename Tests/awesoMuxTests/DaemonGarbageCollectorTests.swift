import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxCore
import Darwin
import Foundation
import Testing

@testable import awesoMux

@Suite("Daemon garbage collector launch policy")
struct DaemonGarbageCollectorTests {
    private static let orphanUUID = "44444444-4444-4444-8444-444444444444"

    private func makeStatusDirectory(files: [String: Date]) throws -> String {
        let directory = NSTemporaryDirectory() + "gc-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (name, mtime) in files {
            let path = directory + "/" + name
            FileManager.default.createFile(atPath: path, contents: Data("{}".utf8))
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: path)
        }
        return directory
    }

    @Test("status sweep deletes an aged orphan file and nothing else")
    func statusSweepDeletesOrphans() throws {
        let old = Date(timeIntervalSinceNow: -86_400)
        let orphan = "\(Self.orphanUUID)-0a1b2c3d.status.jsonl"
        let fresh = "\(Self.orphanUUID)-ffffffff.status.jsonl"
        let directory = try makeStatusDirectory(files: [
            orphan: old,
            fresh: Date(),  // inside the grace window → spared
            "unrelated.txt": old,
        ])
        defer { try? FileManager.default.removeItem(atPath: directory) }

        DaemonGarbageCollector.sweepStaleStatusFiles(
            live: [],
            gcStart: Int(Date().timeIntervalSince1970),
            directory: directory
        )

        let survivors = try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
        #expect(survivors == [fresh, "unrelated.txt"])
    }

    @Test("status sweep deletes nothing when the session list is unavailable")
    func statusSweepAbortsOnNilList() throws {
        let orphan = "\(Self.orphanUUID)-0a1b2c3d.status.jsonl"
        let directory = try makeStatusDirectory(files: [
            orphan: Date(timeIntervalSinceNow: -86_400)
        ])
        defer { try? FileManager.default.removeItem(atPath: directory) }

        DaemonGarbageCollector.sweepStaleStatusFiles(
            live: nil,
            gcStart: Int(Date().timeIntervalSince1970),
            directory: directory
        )

        #expect(FileManager.default.fileExists(atPath: directory + "/" + orphan))
    }

    @Test("status sweep never removes a directory squatting a status name")
    func statusSweepSparesDirectories() throws {
        let directory = try makeStatusDirectory(files: [:])
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let squatter = directory + "/\(Self.orphanUUID)-0a1b2c3d.status.jsonl"
        try FileManager.default.createDirectory(atPath: squatter, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: squatter
        )

        DaemonGarbageCollector.sweepStaleStatusFiles(
            live: [],
            gcStart: Int(Date().timeIntervalSince1970),
            directory: directory
        )

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: squatter, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("status sweep spares attached sessions, reclaims unattached generations")
    func statusSweepUsesAttachmentAsTheDiscriminator() throws {
        let sessionID = TerminalSessionID(rawValue: Self.orphanUUID)!
        let file = "\(Self.orphanUUID)-0a1b2c3d.status.jsonl"
        let directory = try makeStatusDirectory(files: [
            file: Date(timeIntervalSinceNow: -86_400)
        ])
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let gcStart = Int(Date().timeIntervalSince1970)

        // An attached client (clients > 0) protects the file however old.
        DaemonGarbageCollector.sweepStaleStatusFiles(
            live: [LiveDaemon(id: sessionID, pid: 1, createdEpoch: 1, clients: 1)],
            gcStart: gcStart,
            directory: directory
        )
        #expect(FileManager.default.fileExists(atPath: directory + "/" + file))

        // A live but unattached daemon does not: the stale generation is
        // reclaimed even though the session itself persists.
        DaemonGarbageCollector.sweepStaleStatusFiles(
            live: [LiveDaemon(id: sessionID, pid: 1, createdEpoch: 1, clients: 0)],
            gcStart: gcStart,
            directory: directory
        )
        #expect(!FileManager.default.fileExists(atPath: directory + "/" + file))
    }
    @Test("log sweep deletes aged dead-session logs and their rotated pair")
    func logSweepDeletesOrphans() throws {
        let old = Date(timeIntervalSinceNow: -86_400)
        let deadLog = "\(Self.orphanUUID).log"
        let deadRotated = "\(Self.orphanUUID).log.old"
        let liveUUID = "55555555-5555-4555-8555-555555555555"
        let liveLog = "\(liveUUID).log"
        let liveRotated = "\(liveUUID).log.old"
        let freshOrphanUUID = "66666666-6666-4666-8666-666666666666"
        let freshOrphan = "\(freshOrphanUUID).log"
        let directory = try makeStatusDirectory(files: [
            deadLog: old,  // dead session → stale
            deadRotated: old,  // dead session's rotated log → stale
            liveLog: old,  // live daemon → spared however old
            liveRotated: old,  // live daemon's rotated log → spared
            freshOrphan: Date(),  // dead session but inside grace window → spared
            "zmx.log": old,  // global log, unattributable → spared
            "unrelated.txt": old,
        ])
        defer { try? FileManager.default.removeItem(atPath: directory) }

        DaemonGarbageCollector.sweepSessionLogs(
            live: [LiveDaemon(id: TerminalSessionID(rawValue: liveUUID)!, pid: 1, createdEpoch: 1, clients: 0)],
            owned: [],
            gcStart: Int(Date().timeIntervalSince1970),
            directory: directory
        )

        let survivors = try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
        #expect(survivors == [liveLog, liveRotated, freshOrphan, "unrelated.txt", "zmx.log"])
    }

    @Test("log sweep spares an owned session's log even with no live daemon")
    func logSweepSparesOwnedForResurrection() throws {
        // A session dead at the list snapshot but present in `owned` may be
        // recreated by restore, reopening the same log path mid-sweep — so its
        // log must survive even though no daemon is live for it.
        let ownedUUID = "77777777-7777-4777-8777-777777777777"
        let ownedLog = "\(ownedUUID).log"
        let orphanLog = "\(Self.orphanUUID).log"
        let old = Date(timeIntervalSinceNow: -86_400)
        let directory = try makeStatusDirectory(files: [ownedLog: old, orphanLog: old])
        defer { try? FileManager.default.removeItem(atPath: directory) }

        DaemonGarbageCollector.sweepSessionLogs(
            live: [],
            owned: [TerminalSessionID(rawValue: ownedUUID)!],
            gcStart: Int(Date().timeIntervalSince1970),
            directory: directory
        )

        #expect(FileManager.default.fileExists(atPath: directory + "/" + ownedLog))
        #expect(!FileManager.default.fileExists(atPath: directory + "/" + orphanLog))
    }

    @Test("log sweep deletes nothing when the session list is unavailable")
    func logSweepAbortsOnNilList() throws {
        let orphan = "\(Self.orphanUUID).log"
        let directory = try makeStatusDirectory(files: [
            orphan: Date(timeIntervalSinceNow: -86_400)
        ])
        defer { try? FileManager.default.removeItem(atPath: directory) }

        DaemonGarbageCollector.sweepSessionLogs(
            live: nil,
            owned: [],
            gcStart: Int(Date().timeIntervalSince1970),
            directory: directory
        )

        #expect(FileManager.default.fileExists(atPath: directory + "/" + orphan))
    }

    @Test("log sweep never removes a directory squatting a log name")
    func logSweepSparesDirectories() throws {
        let directory = try makeStatusDirectory(files: [:])
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let squatter = directory + "/\(Self.orphanUUID).log"
        try FileManager.default.createDirectory(atPath: squatter, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: squatter
        )

        DaemonGarbageCollector.sweepSessionLogs(
            live: [],
            owned: [],
            gcStart: Int(Date().timeIntervalSince1970),
            directory: directory
        )

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: squatter, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("command bridge enablement is not a launch sweep prerequisite")
    func commandBridgeEnablementIsNotAPrerequisite() {
        let bridgeDisabled = DaemonGarbageCollector.launchSweepConfiguration(
            terminalSettings: TerminalConfig(
                commandBridgeEnabled: false,
                daemonIdleCapEnabled: true,
                daemonIdleCapMinutes: 42
            ),
            isRestoreEnabled: true,
            hasUnresolvedRecoveryWarning: false
        )
        let bridgeEnabled = DaemonGarbageCollector.launchSweepConfiguration(
            terminalSettings: TerminalConfig(
                commandBridgeEnabled: true,
                daemonIdleCapEnabled: true,
                daemonIdleCapMinutes: 42
            ),
            isRestoreEnabled: true,
            hasUnresolvedRecoveryWarning: false
        )

        #expect(bridgeDisabled?.capThresholdSeconds == 2_520)
        #expect(bridgeEnabled == bridgeDisabled)
    }

    // MARK: - Idle classification resolves the daemon, not its shell

    /// `amx list` publishes the forkpty shell child, so `AmxBackend.isIdle` has
    /// to resolve the daemon before classifying. These pin the resolution and
    /// its fail-busy default; `DaemonGCPlan.isIdle` itself is covered in Core.
    private func listed(shellPID: Int32, daemonPID: Int32? = nil) -> LiveDaemon {
        LiveDaemon(
            id: TerminalSessionID(rawValue: Self.orphanUUID)!, pid: shellPID, createdEpoch: 10, clients: 0,
            daemonPID: daemonPID)
    }

    /// The exact reap-a-live-session shape: the pty child exec'd an agent, so
    /// it keeps the listed pid and has no children of its own. Classifying from
    /// the listed pid reads that as idle; classifying from the daemon sees a
    /// non-shell child and reads busy.
    private var agentSnapshot: [ProcEntry] {
        [
            ProcEntry(pid: 69206, ppid: 1, command: "amx"),
            ProcEntry(pid: 69207, ppid: 69206, command: "claude"),
        ]
    }

    @Test("idle: a detached session whose shell exec'd an agent is busy, resolved via daemon_pid")
    func idleResolvesViaDaemonPID() {
        #expect(!AmxBackend.isIdle(listed(shellPID: 69207, daemonPID: 69206), snapshot: agentSnapshot))
        // The shipped bug, pinned: from the shell pid the agent looks childless.
        #expect(DaemonGCPlan.isIdle(daemonPID: 69207, in: agentSnapshot))
    }

    @Test("idle: the same session is busy when the daemon is resolved via the shell's ppid")
    func idleResolvesViaParent() {
        #expect(!AmxBackend.isIdle(listed(shellPID: 69207), snapshot: agentSnapshot))
    }

    @Test("idle: an unresolvable daemon classifies busy, never idle")
    func unresolvableDaemonIsBusy() {
        // Idle is the reap-ward answer, so an unresolvable daemon must not land
        // there — reachable whenever a truncated `ps` drops the shell's row.
        #expect(!AmxBackend.isIdle(listed(shellPID: 69207), snapshot: []))
        #expect(
            !AmxBackend.isIdle(
                listed(shellPID: 69207), snapshot: [ProcEntry(pid: 69207, ppid: 1, command: "-zsh")]))
    }

    @Test("idle: a resolved daemon whose only child is a childless shell is still idle")
    func resolvedIdleDaemonStaysIdle() {
        let snapshot = [
            ProcEntry(pid: 69206, ppid: 1, command: "amx"),
            ProcEntry(pid: 69207, ppid: 69206, command: "-zsh"),
        ]
        #expect(AmxBackend.isIdle(listed(shellPID: 69207, daemonPID: 69206), snapshot: snapshot))
        #expect(AmxBackend.isIdle(listed(shellPID: 69207), snapshot: snapshot))
    }

    @Test("restore and recovery guards still suppress launch sweeps")
    func safetyGuardsSuppressSweep() {
        #expect(
            DaemonGarbageCollector.launchSweepConfiguration(
                terminalSettings: .defaultValue,
                isRestoreEnabled: false,
                hasUnresolvedRecoveryWarning: false
            ) == nil)
        #expect(
            DaemonGarbageCollector.launchSweepConfiguration(
                terminalSettings: .defaultValue,
                isRestoreEnabled: true,
                hasUnresolvedRecoveryWarning: true
            ) == nil)
    }

    // MARK: - sessionSocketExists (INT-914 profile fence)

    @Test("session socket check: a real bound unix socket is owned")
    func sessionSocketExistsAcceptsBoundSocket() throws {
        let uuid = Self.orphanUUID
        // Short path: the 104-byte sockaddr_un budget can't hold a
        // NSTemporaryDirectory-based fixture dir plus a 36-char session name.
        let directory = "/tmp/amx-gc-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/" + uuid

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(listener >= 0)
        defer { Darwin.close(listener) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, length)
            }
        }
        #expect(bindResult == 0)

        #expect(DaemonGarbageCollector.sessionSocketExists(named: uuid, in: directory))
    }

    @Test("session socket check: a stale socket file left by a dead daemon still proves ownership")
    func sessionSocketExistsAcceptsStaleSocketFile() throws {
        let uuid = Self.orphanUUID
        // Short path: the 104-byte sockaddr_un budget can't hold a
        // NSTemporaryDirectory-based fixture dir plus a 36-char session name.
        let directory = "/tmp/amx-gc-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/" + uuid

        // Bind a real listener, then close it WITHOUT unlinking the path —
        // the exact residue a SIGKILLed daemon leaves behind. The entry stays
        // socket-typed on disk while its endpoint is gone.
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(listener >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, length)
            }
        }
        #expect(bindResult == 0)
        Darwin.close(listener)

        // Ownership comes from WHERE the entry lives (only this profile's
        // daemons write here), not from whether a listener survives — a
        // stale entry must keep admitting this profile's orphaned attach
        // clients to the sweep, so pin that reading here.
        #expect(DaemonGarbageCollector.sessionSocketExists(named: uuid, in: directory))
    }

    @Test("session socket check: absent, regular file, and squatting directory are all foreign")
    func sessionSocketExistsRejectsNonSockets() throws {
        let uuid = Self.orphanUUID
        let directory = try makeStatusDirectory(files: [uuid: Date()])
        defer { try? FileManager.default.removeItem(atPath: directory) }

        // Squatting regular file: must not authenticate a cross-profile kill.
        #expect(!DaemonGarbageCollector.sessionSocketExists(named: uuid, in: directory))
        // Absent entry: reads as "not ours", spares the candidate.
        #expect(
            !DaemonGarbageCollector.sessionSocketExists(
                named: "99999999-9999-4999-8999-999999999999", in: directory))
        // Directory squatting the name: also foreign.
        let absentUUID = "88888888-8888-4888-8888-888888888888"
        try FileManager.default.createDirectory(atPath: directory + "/" + absentUUID, withIntermediateDirectories: false)
        #expect(!DaemonGarbageCollector.sessionSocketExists(named: absentUUID, in: directory))
        // Symlink to anything: `lstat` reads the link itself, never the target.
        let linkUUID = "77777777-7777-4777-8777-777777777777"
        try FileManager.default.createSymbolicLink(
            atPath: directory + "/" + linkUUID, withDestinationPath: "/tmp")
        #expect(!DaemonGarbageCollector.sessionSocketExists(named: linkUUID, in: directory))
    }
}
