import AppKit
import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite("Agent runtime event bridge", .serialized)
struct AgentRuntimeEventBridgeTests {
    @MainActor
    @Test("a new watch consumes a buffered terminal session end")
    func newWatchConsumesBufferedTerminalSessionEnd() throws {
        try Self.withTemporaryDirectory { directory in
            try SessionPersistence.withTemporarySupportDirectory(directory) {
                let paneID = TerminalPane.ID()
                let eventsDirectory = directory.appending(
                    path: "runtime-events",
                    directoryHint: .isDirectory
                )
                try FileManager.default.createDirectory(
                    at: eventsDirectory,
                    withIntermediateDirectories: true
                )
                let eventFile = eventsDirectory.appending(path: "\(paneID.uuidString).jsonl")
                let oldEnd = #"{"v":1,"source":"pi","execution":"idle","phase":"sessionEnd"}"#
                try Data((oldEnd + "\n").utf8).write(to: eventFile)

                let bridge = AgentRuntimeEventBridge()
                var appliedEvents: [AgentRuntimeEvent] = []
                let environment = bridge.environment(
                    sessionID: TerminalSession.ID(),
                    paneID: paneID,
                    enabledFileDropSources: []
                ) { event in
                    appliedEvents.append(event)
                }

                bridge.drainRuntimeEventsForTesting(paneID: paneID)
                #expect(appliedEvents.map(\.phase) == [.sessionEnd])

                let newStart = #"{"v":1,"source":"pi","execution":"idle","phase":"sessionStart"}"#
                let handle = try FileHandle(forWritingTo: environment.eventFileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((newStart + "\n").utf8))
                try handle.close()
                bridge.drainRuntimeEventsForTesting(paneID: paneID)

                #expect(appliedEvents.map(\.phase) == [.sessionEnd, .sessionStart])
                bridge.stopWatchingAll()
            }
        }
    }

    @MainActor
    @Test("a newer buffered lifecycle prevents an old session end replay")
    func newerBufferedLifecyclePreventsOldSessionEndReplay() throws {
        try Self.withTemporaryDirectory { directory in
            try SessionPersistence.withTemporarySupportDirectory(directory) {
                let paneID = TerminalPane.ID()
                let eventsDirectory = directory.appending(
                    path: "runtime-events",
                    directoryHint: .isDirectory
                )
                try FileManager.default.createDirectory(
                    at: eventsDirectory,
                    withIntermediateDirectories: true
                )
                let eventFile = eventsDirectory.appending(path: "\(paneID.uuidString).jsonl")
                let bufferedEvents = """
                    {"v":1,"source":"pi","execution":"idle","phase":"sessionEnd"}
                    {"v":1,"source":"pi","execution":"idle","phase":"sessionStart"}
                    """
                try Data((bufferedEvents + "\n").utf8).write(to: eventFile)

                let bridge = AgentRuntimeEventBridge()
                var appliedEvents: [AgentRuntimeEvent] = []
                bridge.environment(
                    sessionID: TerminalSession.ID(),
                    paneID: paneID,
                    enabledFileDropSources: []
                ) { appliedEvents.append($0) }

                #expect(appliedEvents.isEmpty)
                bridge.stopWatchingAll()
            }
        }
    }

    @MainActor
    @Test("only the final complete nonempty buffered record can provide lifecycle truth")
    func finalBufferedRecordIsAuthoritative() throws {
        let invalidFinalRecords = [
            "not-json",
            #"{"v":2,"source":"pi","execution":"idle","phase":"sessionStart"}"#,
            #"{"v":1,"source":"future","execution":"idle","phase":"sessionEnd"}"#,
            String(repeating: "x", count: AgentRuntimeEvent.maximumLineByteCount + 1),
        ]

        for invalidFinalRecord in invalidFinalRecords {
            try Self.withTemporaryDirectory { directory in
                let paneID = TerminalPane.ID()
                let eventsDirectory = directory.appending(path: "runtime-events")
                try FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
                let eventFile = eventsDirectory.appending(path: "\(paneID.uuidString).jsonl")
                let oldEnd = #"{"v":1,"source":"pi","execution":"idle","phase":"sessionEnd"}"#
                try Data("\(oldEnd)\n\(invalidFinalRecord)\n".utf8).write(to: eventFile)

                var appliedEvents: [AgentRuntimeEvent] = []
                let bridge = AgentRuntimeEventBridge(runtimeEventsDirectoryURL: eventsDirectory)
                bridge.environment(
                    sessionID: TerminalSession.ID(),
                    paneID: paneID,
                    enabledFileDropSources: []
                ) { appliedEvents.append($0) }

                #expect(appliedEvents.isEmpty)
                bridge.stopWatchingAll()
            }
        }
    }

    @MainActor
    @Test("dense trailing empty records do not allocate or decode the whole file")
    func denseTrailingNewlinesUseBoundedTailScan() throws {
        try Self.withTemporaryDirectory { directory in
            let paneID = TerminalPane.ID()
            let eventsDirectory = directory.appending(path: "runtime-events")
            try FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
            let eventFile = eventsDirectory.appending(path: "\(paneID.uuidString).jsonl")
            let end = #"{"v":1,"source":"pi","execution":"idle","phase":"sessionEnd"}"#
            try Data((end + "\n" + String(repeating: "\n", count: 512 * 1024)).utf8).write(to: eventFile)

            var phases: [AgentRuntimePhase] = []
            let bridge = AgentRuntimeEventBridge(runtimeEventsDirectoryURL: eventsDirectory)
            bridge.environment(
                sessionID: TerminalSession.ID(),
                paneID: paneID,
                enabledFileDropSources: []
            ) { event in
                if let phase = event.phase {
                    phases.append(phase)
                }
            }

            #expect(phases == [.sessionEnd])
            bridge.stopWatchingAll()
        }
    }

    @MainActor
    @Test("inode rotation invalidates the initial buffered decision")
    func inodeRotationInvalidatesInitialSnapshot() throws {
        try Self.initialSnapshotMutationTest { eventFile, replacement in
            let rotatedFile = eventFile.appendingPathExtension("rotated")
            try FileManager.default.moveItem(at: eventFile, to: rotatedFile)
            try replacement.write(to: eventFile)
        }
    }

    @MainActor
    @Test("truncate and regrow invalidates the initial buffered decision")
    func truncateRegrowInvalidatesInitialSnapshot() throws {
        try Self.initialSnapshotMutationTest { eventFile, replacement in
            let handle = try FileHandle(forWritingTo: eventFile)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: replacement)
            try handle.close()
        }
    }

    @MainActor
    @Test("valid runtime activity updates state without creating diagnostic rows")
    func validRuntimeActivityIsNotDuplicatedIntoDiagnostics() throws {
        try Self.withTemporaryDirectory { directory in
            try SessionPersistence.withTemporarySupportDirectory(directory) {
                var diagnostics: [LocalDiagnosticEventInput] = []
                let bridge = AgentRuntimeEventBridge(
                    diagnosticEventHandler: { diagnostics.append($0) }
                )
                let sessionID = TerminalSession.ID()
                let paneID = TerminalPane.ID()
                var appliedEvents: [AgentRuntimeEvent] = []
                let environment = bridge.environment(
                    sessionID: sessionID,
                    paneID: paneID,
                    enabledFileDropSources: []
                ) { appliedEvents.append($0) }
                let event = #"{"v":1,"source":"codex","execution":"thinking","phase":"toolStart"}"#
                let handle = try FileHandle(forWritingTo: environment.eventFileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((event + "\n").utf8))
                try handle.close()

                bridge.drainRuntimeEventsForTesting(paneID: paneID)

                #expect(appliedEvents.count == 1)
                #expect(diagnostics.isEmpty)
                bridge.stopWatchingAll()
            }
        }
    }

    @MainActor
    @Test("malformed runtime lines coalesce into one diagnostic event per drain")
    func malformedLinesCoalescePerDrain() throws {
        try Self.withTemporaryDirectory { directory in
            try SessionPersistence.withTemporarySupportDirectory(directory) {
                var diagnostics: [LocalDiagnosticEventInput] = []
                let bridge = AgentRuntimeEventBridge(
                    diagnosticEventHandler: { diagnostics.append($0) }
                )
                let sessionID = TerminalSession.ID()
                let paneID = TerminalPane.ID()
                var appliedEvents: [AgentRuntimeEvent] = []
                let environment = bridge.environment(
                    sessionID: sessionID,
                    paneID: paneID,
                    enabledFileDropSources: []
                ) { appliedEvents.append($0) }
                let payload = """
                    not-json
                    {"v":1,"source":"codex","execution":"thinking","phase":"toolStart"}
                    also-not-json
                    still-broken
                    """
                let handle = try FileHandle(forWritingTo: environment.eventFileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((payload + "\n").utf8))
                try handle.close()

                bridge.drainRuntimeEventsForTesting(paneID: paneID)

                #expect(appliedEvents.count == 1)
                #expect(diagnostics == [.runtimeEventRejected])
                bridge.stopWatchingAll()
            }
        }
    }

    @MainActor
    @Test("background authoritative event updates state and triggers notification before reactivation")
    func backgroundEventIsDeliveredBeforeReactivation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-runtime-event-bridge-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = TerminalSession(
            title: "agent",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [session])
        ])
        var tracker = WorkspaceNotificationTracker(groups: store.groups)
        var notificationEvents: [WorkspaceNotificationEvent] = []
        var appliedEventCount = 0
        let notificationCenter = NotificationCenter()
        let bridge = AgentRuntimeEventBridge(
            notificationCenter: notificationCenter,
            initialIsAppActive: true,
            runtimeEventsDirectoryURL: directory.appending(
                path: "runtime-events",
                directoryHint: .isDirectory
            )
        )
        defer { bridge.stopWatchingAll() }
        let environment = bridge.environment(
            sessionID: session.id,
            paneID: session.activePaneID,
            enabledFileDropSources: []
        ) { event in
            guard
                store.applyAgentRuntimeEvent(
                    event,
                    to: session.id,
                    paneID: session.activePaneID,
                    terminalIsFocused: false
                )
            else {
                return
            }
            appliedEventCount += 1
            notificationEvents = tracker.notificationEvents(
                afterUpdating: store.groups,
                selectedSessionID: session.id,
                isAppActive: false
            )
        }

        notificationCenter.post(
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        let event = #"{"v":1,"source":"codex","attentionReason":"permissionPrompt","phase":"notification"}"#
        let handle = try FileHandle(forWritingTo: environment.eventFileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((event + "\n").utf8))
        try handle.close()

        let deadline = ContinuousClock.now + .seconds(3)
        while notificationEvents.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(appliedEventCount == 1)
        #expect(store.session(id: session.id)?.agentState == .needsAttention)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 1)
        #expect(notificationEvents.map(\.kind) == [.needsAttention])
    }

    @MainActor
    @Test("source-open failure retries and delivers in background before reactivation")
    func backgroundSourceOpenFailureRecoversBeforeReactivation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-runtime-event-bridge-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let runtimeEventsDirectory = directory.appending(
            path: "runtime-events",
            directoryHint: .isDirectory
        )
        try Data("block directory creation".utf8).write(to: runtimeEventsDirectory)

        let session = TerminalSession(
            title: "agent",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [session])
        ])
        var tracker = WorkspaceNotificationTracker(groups: store.groups)
        var notificationEvents: [WorkspaceNotificationEvent] = []
        let notificationCenter = NotificationCenter()
        let bridge = AgentRuntimeEventBridge(
            notificationCenter: notificationCenter,
            initialIsAppActive: true,
            runtimeEventsDirectoryURL: runtimeEventsDirectory
        )
        defer { bridge.stopWatchingAll() }
        let environment = bridge.environment(
            sessionID: session.id,
            paneID: session.activePaneID,
            enabledFileDropSources: []
        ) { event in
            guard
                store.applyAgentRuntimeEvent(
                    event,
                    to: session.id,
                    paneID: session.activePaneID,
                    terminalIsFocused: false
                )
            else {
                return
            }
            notificationEvents = tracker.notificationEvents(
                afterUpdating: store.groups,
                selectedSessionID: session.id,
                isAppActive: false,
                notifyOnTurnDone: true
            )
        }

        notificationCenter.post(
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        try FileManager.default.removeItem(at: runtimeEventsDirectory)
        try FileManager.default.createDirectory(
            at: runtimeEventsDirectory,
            withIntermediateDirectories: true
        )
        let fileCreationDeadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: environment.eventFileURL.path),
            ContinuousClock.now < fileCreationDeadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }

        try #require(FileManager.default.fileExists(atPath: environment.eventFileURL.path))
        let event = #"{"v":1,"source":"codex","execution":"waiting","phase":"stop"}"#
        let handle = try FileHandle(forWritingTo: environment.eventFileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((event + "\n").utf8))
        try handle.close()

        let deadline = ContinuousClock.now + .seconds(3)
        while notificationEvents.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.session(id: session.id)?.agentState == .waiting)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 1)
        #expect(notificationEvents.map(\.kind) == [.turnDone])
    }

    @MainActor
    @Test("same-inode read failure drains after recovery without another event")
    func sameInodeReadFailureRetriesDrain() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-runtime-event-bridge-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = TerminalSession(
            title: "agent",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [session])
        ])
        var tracker = WorkspaceNotificationTracker(groups: store.groups)
        var notificationEvents: [WorkspaceNotificationEvent] = []
        let notificationCenter = NotificationCenter()
        let bridge = AgentRuntimeEventBridge(
            notificationCenter: notificationCenter,
            initialIsAppActive: true,
            runtimeEventsDirectoryURL: directory.appending(
                path: "runtime-events",
                directoryHint: .isDirectory
            )
        )
        defer { bridge.stopWatchingAll() }
        let environment = bridge.environment(
            sessionID: session.id,
            paneID: session.activePaneID,
            enabledFileDropSources: []
        ) { event in
            guard
                store.applyAgentRuntimeEvent(
                    event,
                    to: session.id,
                    paneID: session.activePaneID,
                    terminalIsFocused: false
                )
            else {
                return
            }
            notificationEvents = tracker.notificationEvents(
                afterUpdating: store.groups,
                selectedSessionID: session.id,
                isAppActive: false
            )
        }

        let handle = try FileHandle(forWritingTo: environment.eventFileURL)
        defer { try? handle.close() }
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: environment.eventFileURL.path
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: environment.eventFileURL.path
        )
        notificationCenter.post(
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        let event = #"{"v":1,"source":"codex","attentionReason":"permissionPrompt","phase":"notification"}"#
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((event + "\n").utf8))
        try await Task.sleep(for: .milliseconds(50))
        notificationCenter.post(
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: environment.eventFileURL.path
        )

        let deadline = ContinuousClock.now + .seconds(3)
        while notificationEvents.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.session(id: session.id)?.agentState == .needsAttention)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 1)
        #expect(notificationEvents.map(\.kind) == [.needsAttention])
    }

    @MainActor
    @Test("drain rejects symlink event path without parsing target")
    func drainRejectsSymlinkEventPathWithoutParsingTarget() throws {
        try Self.withTemporaryDirectory { directory in
            try SessionPersistence.withTemporarySupportDirectory(directory) {
                let bridge = AgentRuntimeEventBridge()
                let sessionID = TerminalSession.ID()
                let paneID = TerminalPane.ID()
                var appliedEvents: [AgentRuntimeEvent] = []

                let environment = bridge.environment(
                    sessionID: sessionID,
                    paneID: paneID,
                    enabledFileDropSources: []
                ) { event in
                    appliedEvents.append(event)
                }

                let target = directory.appending(path: "target.jsonl")
                let spoofedEvent = #"{"v":1,"source":"codex","execution":"thinking","phase":"toolStart"}"#
                try Data((spoofedEvent + "\n").utf8).write(to: target)
                try FileManager.default.removeItem(at: environment.eventFileURL)
                try FileManager.default.createSymbolicLink(
                    at: environment.eventFileURL,
                    withDestinationURL: target
                )

                bridge.drainRuntimeEventsForTesting(paneID: paneID)

                #expect(appliedEvents.isEmpty)
                bridge.stopWatchingAll()
            }
        }
    }

    @MainActor
    private static func initialSnapshotMutationTest(
        _ mutation: @escaping (URL, Data) throws -> Void
    ) throws {
        try Self.withTemporaryDirectory { directory in
            let paneID = TerminalPane.ID()
            let eventsDirectory = directory.appending(path: "runtime-events")
            try FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
            let eventFile = eventsDirectory.appending(path: "\(paneID.uuidString).jsonl")
            let end = #"{"v":1,"source":"pi","execution":"idle","phase":"sessionEnd"}"# + "\n"
            let replacement = #"{"v":1,"source":"pi","execution":"idle","phase":"toolStart" }"# + "\n"
            #expect(end.utf8.count == replacement.utf8.count)
            try Data(end.utf8).write(to: eventFile)

            var didMutate = false
            var mutationError: Error?
            let bridge = AgentRuntimeEventBridge(
                runtimeEventsDirectoryURL: eventsDirectory,
                initialSnapshotInterposer: { url in
                    guard !didMutate else { return }
                    didMutate = true
                    do {
                        try mutation(url, Data(replacement.utf8))
                    } catch {
                        mutationError = error
                    }
                }
            )
            var phases: [AgentRuntimePhase] = []
            bridge.environment(
                sessionID: TerminalSession.ID(),
                paneID: paneID,
                enabledFileDropSources: []
            ) { event in
                if let phase = event.phase {
                    phases.append(phase)
                }
            }
            try #require(mutationError == nil)
            #expect(phases.isEmpty)

            bridge.retrySourceForTesting(paneID: paneID)
            #expect(phases.isEmpty)
            bridge.stopWatchingAll()
        }
    }

    private static func withTemporaryDirectory(_ operation: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-runtime-event-bridge-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try operation(directory)
    }
}
