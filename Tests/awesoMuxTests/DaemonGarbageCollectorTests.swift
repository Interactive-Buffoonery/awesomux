import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxCore
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
            gcStart: Int(Date().timeIntervalSince1970),
            directory: directory
        )

        let survivors = try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
        #expect(survivors == [liveLog, liveRotated, freshOrphan, "unrelated.txt", "zmx.log"])
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
}
