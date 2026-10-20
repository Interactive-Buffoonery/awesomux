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

    enum UnavailableSessionListCase: String, CaseIterable {
        case statusSweepAbortsOnNilList
        case logSweepAbortsOnNilList
    }

    @Test(arguments: UnavailableSessionListCase.allCases)
    func unavailableSessionList(_ scenario: UnavailableSessionListCase) throws {
        switch scenario {
        case .statusSweepAbortsOnNilList:
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
        case .logSweepAbortsOnNilList:
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
    }

    enum DirectorySquattersCase: String, CaseIterable {
        case statusSweepSparesDirectories
        case logSweepSparesDirectories
    }

    @Test(arguments: DirectorySquattersCase.allCases)
    func directorySquatters(_ scenario: DirectorySquattersCase) throws {
        switch scenario {
        case .statusSweepSparesDirectories:
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
        case .logSweepSparesDirectories:
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

    enum IdleResolutionCase: String, CaseIterable {
        case idleResolvesViaDaemonPID
        case idleResolvesViaParent
        case unresolvableDaemonIsBusy
    }

    @Test(arguments: IdleResolutionCase.allCases)
    func idleResolution(_ scenario: IdleResolutionCase) {
        switch scenario {
        case .idleResolvesViaDaemonPID:
            #expect(!AmxBackend.isIdle(listed(shellPID: 69207, daemonPID: 69206), snapshot: agentSnapshot))
            // The shipped bug, pinned: from the shell pid the agent looks childless.
            #expect(DaemonGCPlan.isIdle(daemonPID: 69207, in: agentSnapshot))
        case .idleResolvesViaParent:
            #expect(!AmxBackend.isIdle(listed(shellPID: 69207), snapshot: agentSnapshot))
        case .unresolvableDaemonIsBusy:
            // Idle is the reap-ward answer, so an unresolvable daemon must not land
            // there — reachable whenever a truncated `ps` drops the shell's row.
            #expect(!AmxBackend.isIdle(listed(shellPID: 69207), snapshot: []))
            #expect(
                !AmxBackend.isIdle(
                    listed(shellPID: 69207), snapshot: [ProcEntry(pid: 69207, ppid: 1, command: "-zsh")]))
        }
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

    @Test(arguments: [false, true])
    func sessionSocketExistsAcceptsBoundAndStaleSocket(stale: Bool) throws {
        let uuid = Self.orphanUUID
        // Short path: the 104-byte sockaddr_un budget can't hold a
        // NSTemporaryDirectory-based fixture dir plus a 36-char session name.
        let directory = "/tmp/amx-gc-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/" + uuid

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(listener >= 0)
        var listenerOpen = true
        defer { if listenerOpen { Darwin.close(listener) } }
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

        if stale {
            Darwin.close(listener)
            listenerOpen = false
        }
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

    // MARK: - Targeted process snapshot

    @Test(arguments: [true, false])
    func orphanConfirmUsesFreshSnapshotForDaemonParents(isDaemonParent: Bool) async {
        let listedSession = TerminalSessionID(rawValue: Self.orphanUUID)!
        let candidatePID: Int32 = 500
        let freshShellPID: Int32 = 501
        let recorder = OrphanConfirmRecorder()

        await DaemonGarbageCollector.reapOrphanAttachClients(
            live: [
                LiveDaemon(
                    id: listedSession, pid: 100, createdEpoch: 1, clients: 1,
                    daemonPID: 99)
            ],
            snapshot: [
                ProcEntry(pid: candidatePID, ppid: 1, command: "/Applications/awesoMux.app/Contents/MacOS/amx")
            ],
            listSessionsRawOutput: {
                "name=\(Self.orphanUUID)\tpid=\(freshShellPID)\tcreated=1\tclients=1"
            },
            processSnapshot: { pids in
                return [ProcEntry(pid: freshShellPID, ppid: isDaemonParent ? candidatePID : 99, command: "-zsh")]
            },
            attachProcessSamples: { pids in
                return [
                    DaemonGCPlan.AttachProcessSample(
                        pid: candidatePID, ppid: 1, etimeSeconds: 3_600,
                        argv0: "/Applications/awesoMux.app/Contents/MacOS/amx",
                        subcommand: "attach", sessionArgument: Self.orphanUUID)
                ]
            },
            sessionSocketExists: { _ in true },
            signalConfirmed: { confirmed in
                await recorder.recordSignals(confirmed.map(\.pid))
                return confirmed.count
            }
        )

        #expect(await recorder.signaledPIDs == (isDaemonParent ? [] : [candidatePID]))
    }

    // MARK: - Orphan attach signaling

    enum OrphanSignallingCase: String, CaseIterable {
        case orphanSignalFailsClosedWhenTermSampleIsUnavailable
        case orphanSignalRechecksIdentityBeforeTerm
        case orphanSignalRechecksIdentityBeforeKill
        case orphanSignalFailsClosedWhenKillSampleIsUnavailable
        case orphanSignalSkipsEscalationWhenGraceWaitIsCancelled
        case orphanSignalEscalatesStableIdentity
    }

    @Test(arguments: OrphanSignallingCase.allCases)
    func orphanSignalling(_ scenario: OrphanSignallingCase) async {
        let expected = orphanSample(etimeSeconds: 3_600)
        let stillExpected = orphanSample(etimeSeconds: 3_601)
        let replacement = DaemonGCPlan.AttachProcessSample(
            pid: expected.pid, ppid: 1, etimeSeconds: 1,
            argv0: "unrelated", subcommand: nil, sessionArgument: nil)
        let observations: [[DaemonGCPlan.AttachProcessSample]]
        let expectedSignals: [String]
        switch scenario {
        case .orphanSignalFailsClosedWhenTermSampleIsUnavailable:
            observations = []
            expectedSignals = []
        case .orphanSignalRechecksIdentityBeforeTerm:
            observations = [[replacement]]
            expectedSignals = []
        case .orphanSignalRechecksIdentityBeforeKill:
            observations = [[stillExpected], [replacement]]
            expectedSignals = ["\(expected.pid):\(SIGTERM)"]
        case .orphanSignalFailsClosedWhenKillSampleIsUnavailable:
            observations = [[stillExpected]]
            expectedSignals = ["\(expected.pid):\(SIGTERM)"]
        case .orphanSignalSkipsEscalationWhenGraceWaitIsCancelled:
            // A second matching sample means only the cancellation can stop SIGKILL.
            observations = [[stillExpected], [orphanSample(etimeSeconds: 3_602)]]
            expectedSignals = ["\(expected.pid):\(SIGTERM)"]
        case .orphanSignalEscalatesStableIdentity:
            observations = [[stillExpected], [orphanSample(etimeSeconds: 3_602)]]
            expectedSignals = ["\(expected.pid):\(SIGTERM)", "\(expected.pid):\(SIGKILL)"]
        }
        let samples = SampleSequence(observations)
        let signals = SignalRecorder()
        let cancelGraceWait = scenario == .orphanSignalSkipsEscalationWhenGraceWaitIsCancelled
        let task = Task {
            await DaemonGarbageCollector.signalConfirmedOrphanAttachClients(
                [expected],
                sampleProcesses: { _ in await samples.next() },
                processExists: { _ in true },
                signalProcess: { pid, signal in await signals.record(pid: pid, signal: signal) },
                waitForGrace: { _ in
                    if cancelGraceWait {
                        withUnsafeCurrentTask { $0?.cancel() }
                        try Task.checkCancellation()
                    }
                }
            )
        }
        #expect(await task.value == (expectedSignals.isEmpty ? 0 : 1))
        #expect(await signals.events == expectedSignals)
    }

    private func orphanSample(etimeSeconds: Int) -> DaemonGCPlan.AttachProcessSample {
        DaemonGCPlan.AttachProcessSample(
            pid: 500, ppid: 1, etimeSeconds: etimeSeconds,
            argv0: "/Applications/awesoMux.app/Contents/MacOS/amx", subcommand: "attach",
            sessionArgument: Self.orphanUUID)
    }

    private actor SampleSequence {
        private var values: [[DaemonGCPlan.AttachProcessSample]]

        init(_ values: [[DaemonGCPlan.AttachProcessSample]]) {
            self.values = values
        }

        func next() -> [DaemonGCPlan.AttachProcessSample]? {
            values.isEmpty ? nil : values.removeFirst()
        }
    }

    private actor SignalRecorder {
        private(set) var events: [String] = []

        func record(pid: Int32, signal: Int32) -> Int32 {
            events.append("\(pid):\(signal)")
            return 0
        }
    }

    private actor OrphanConfirmRecorder {
        private(set) var signaledPIDs: [Int32] = []

        func recordSignals(_ pids: [Int32]) {
            signaledPIDs.append(contentsOf: pids)
        }
    }
}
