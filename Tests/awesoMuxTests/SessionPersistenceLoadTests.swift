@testable import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("SessionPersistence load")
struct SessionPersistenceLoadTests {
    @Test("dirty snapshot returns sanitized warning")
    func dirtySnapshotReturnsSanitizedWarning() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            let snapshot = Self.snapshot(groupName: "ops\u{202E}")
            try Self.write(snapshot, to: tempDir)

            let result = SessionPersistence.load()

            guard case let .sanitizedRestore(summary, _, _) = result.recoveryWarning?.kind else {
                Issue.record("expected sanitized restore warning")
                return
            }
            #expect(summary.groupNameAdjustments == 1)
            #expect(result.store.groups.first?.name == "ops")
        }
    }

    @Test("sanitized restore copies original snapshot before cleaned save")
    func sanitizedRestoreCopiesOriginalSnapshotBeforeCleanedSave() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            let snapshot = Self.snapshot(groupName: "ops\u{202E}")
            let originalData = try Self.write(snapshot, to: tempDir)

            let result = SessionPersistence.load()

            guard case let .sanitizedRestore(_, archivedSnapshotURL, archiveError) = result.recoveryWarning?.kind else {
                Issue.record("expected sanitized restore warning")
                return
            }
            let archiveURL = try #require(archivedSnapshotURL)
            #expect(archiveError == nil)
            #expect(FileManager.default.fileExists(atPath: archiveURL.path))
            #expect(try Data(contentsOf: archiveURL) == originalData)
            #expect(archiveURL.deletingLastPathComponent() == tempDir)
            #expect(archiveURL.lastPathComponent.contains("session-state.sanitized-"))
            // The archive can mirror sensitive cwds, so it must be private.
            let permissions = try FileManager.default
                .attributesOfItem(atPath: archiveURL.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.int16Value == 0o600)
        }
    }

    @Test("structural-only adjustment archives silently without a warning")
    func structuralOnlyAdjustmentArchivesSilently() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            // Two sessions share an ID: restore rewrites the duplicate (a
            // structural change) but there's nothing user-facing to explain, so
            // the original is archived silently and no warning surfaces.
            let duplicateID = UUID()
            let firstPane = TerminalPane(title: "a", workingDirectory: "~", executionPlan: .local)
            let secondPane = TerminalPane(title: "b", workingDirectory: "~", executionPlan: .local)
            let first = TerminalSession(
                id: duplicateID,
                title: "a",
                workingDirectory: "~",
                agentKind: .shell,
                agentState: .idle,
                layout: .pane(firstPane),
                activePaneID: firstPane.id
            )
            let second = TerminalSession(
                id: duplicateID,
                title: "b",
                workingDirectory: "~",
                agentKind: .shell,
                agentState: .idle,
                layout: .pane(secondPane),
                activePaneID: secondPane.id
            )
            let snapshot = SessionSnapshot(
                groups: [SessionGroup(name: "ops", sessions: [first, second])],
                selectedSessionID: duplicateID
            )
            try Self.write(snapshot, to: tempDir)

            let result = SessionPersistence.load()

            #expect(result.recoveryWarning == nil)
            #expect(try !Self.sanitizedArchives(in: tempDir).isEmpty)
        }
    }

    @Test("sanitized restore archive copy failure still warns")
    func sanitizedRestoreArchiveCopyFailureStillWarns() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            let targetURL = tempDir.appending(path: "real-session-state.json")
            _ = try Self.write(Self.snapshot(groupName: "ops\u{202E}"), to: tempDir, url: targetURL)
            let snapshotURL = tempDir.appending(path: "session-state.json")
            try FileManager.default.createSymbolicLink(
                at: snapshotURL,
                withDestinationURL: targetURL
            )

            let result = SessionPersistence.load()

            guard case let .sanitizedRestore(summary, archivedSnapshotURL, archiveError) = result.recoveryWarning?.kind else {
                Issue.record("expected sanitized restore warning")
                return
            }
            #expect(summary.groupNameAdjustments == 1)
            #expect(archivedSnapshotURL == nil)
            #expect(archiveError != nil)
            #expect(((try? snapshotURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink) == true)
        }
    }

    @Test("clean snapshot does not create sanitized archive")
    func cleanSnapshotDoesNotCreateSanitizedArchive() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            try Self.write(Self.snapshot(groupName: "ops"), to: tempDir)

            let result = SessionPersistence.load()

            #expect(result.recoveryWarning == nil)
            #expect(try Self.sanitizedArchives(in: tempDir).isEmpty)
        }
    }

    @Test("remote markdown cache prunes unreferenced snapshots after successful load")
    func remoteMarkdownCachePrunesUnreferencedSnapshotsAfterSuccessfulLoad() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            let cacheDir = tempDir.appending(path: "remote-markdown", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let kept = cacheDir.appending(path: "kept.md")
            let orphan = cacheDir.appending(path: "orphan.md")
            try Data("kept".utf8).write(to: kept)
            try Data("orphan".utf8).write(to: orphan)

            let terminal = TerminalPane(title: "shell", workingDirectory: "~", executionPlan: .local)
            let doc = DocumentPane(
                fileURL: kept,
                title: "kept.md",
                remoteResourceIdentity: ResourceIdentity(
                    location: .remote(RemoteTarget(parsing: "devbox")!),
                    path: ResourcePath(rawValue: "/repo/kept.md")
                )
            )
            let session = TerminalSession(
                title: "shell",
                workingDirectory: "~",
                layout: .split(TerminalSplit(
                    orientation: .vertical,
                    first: .pane(terminal),
                    second: .documentGroup(DocumentGroup(tabs: [doc], selectedTabID: doc.id))
                )),
                activePaneID: terminal.id
            )
            try Self.write(
                SessionSnapshot(
                    groups: [SessionGroup(name: "ops", sessions: [session])],
                    selectedSessionID: session.id
                ),
                to: tempDir
            )

            let result = SessionPersistence.load()
            SessionPersistence.pruneRemoteMarkdownSnapshotsForTesting(keeping: result.store)

            #expect(result.recoveryWarning == nil)
            #expect(FileManager.default.fileExists(atPath: kept.path))
            #expect(!FileManager.default.fileExists(atPath: orphan.path))
        }
    }

    @Test("remote markdown cache keeps recently closed snapshots")
    func remoteMarkdownCacheKeepsRecentlyClosedSnapshots() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            let cacheDir = tempDir.appending(path: "remote-markdown", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let kept = cacheDir.appending(path: "recent.md")
            let orphan = cacheDir.appending(path: "orphan.md")
            try Data("recent".utf8).write(to: kept)
            try Data("orphan".utf8).write(to: orphan)

            let terminal = TerminalPane(title: "shell", workingDirectory: "~", executionPlan: .local)
            let doc = DocumentPane(
                fileURL: kept,
                title: "recent.md",
                remoteResourceIdentity: ResourceIdentity(
                    location: .remote(RemoteTarget(parsing: "devbox")!),
                    path: ResourcePath(rawValue: "/repo/recent.md")
                )
            )
            let layout = TerminalPaneLayout.split(TerminalSplit(
                orientation: .vertical,
                first: .pane(terminal),
                second: .documentGroup(DocumentGroup(tabs: [doc], selectedTabID: doc.id))
            ))
            let recent = RecentlyClosedWorkspace(
                sessionID: UUID(),
                title: "remote docs",
                isTitleUserEdited: false,
                agentKind: .shell,
                layout: layout,
                activePaneID: terminal.id,
                groupID: UUID(),
                groupName: "ops",
                groupRemote: nil,
                indexInGroup: 0,
                closedAt: Date()
            )
            let store = SessionStore(restoring: SessionSnapshot(
                groups: [SessionGroup(name: "ops", sessions: [])],
                selectedSessionID: nil,
                recentlyClosed: [recent]
            ))

            SessionPersistence.pruneRemoteMarkdownSnapshotsForTesting(keeping: store)

            #expect(FileManager.default.fileExists(atPath: kept.path))
            #expect(!FileManager.default.fileExists(atPath: orphan.path))
        }
    }

    @Test("corrupted snapshot recovery leaves remote markdown cache untouched")
    func corruptedSnapshotRecoveryLeavesRemoteMarkdownCacheUntouched() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            let cacheDir = tempDir.appending(path: "remote-markdown", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let cached = cacheDir.appending(path: "kept-for-archive.md")
            try Data("cached".utf8).write(to: cached)
            let snapshotURL = tempDir.appending(path: "session-state.json")
            try Data("{not-json".utf8).write(to: snapshotURL)

            let result = SessionPersistence.load()

            guard case .archivedSnapshot = result.recoveryWarning?.kind else {
                Issue.record("expected archived snapshot warning")
                return
            }
            #expect(FileManager.default.fileExists(atPath: cached.path))
        }
    }

    @Test("malformed remote metadata archives instead of becoming a local group")
    func malformedRemoteMetadataArchivesInsteadOfBecomingLocalGroup() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            let groupID = UUID()
            let json = """
            {
              "schemaVersion": \(SessionSnapshot.currentSchemaVersion),
              "groups": [
                {
                  "id": "\(groupID.uuidString)",
                  "name": "remote",
                  "remote": { "user": "ed" },
                  "sessions": []
                }
              ],
              "selectedSessionID": null
            }
            """
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            try Data(json.utf8).write(to: tempDir.appending(path: "session-state.json"))

            let result = SessionPersistence.load()

            guard case let .archivedSnapshot(archivedSnapshotURL, archiveError) = result.recoveryWarning?.kind else {
                Issue.record("expected malformed remote metadata to be archived")
                return
            }
            #expect(archiveError == nil)
            #expect(archivedSnapshotURL != nil)
            #expect(result.store.groups.isEmpty)
        }
    }

    @Test("remote markdown cache pruning refuses symlinked cache root")
    func remoteMarkdownCachePruningRefusesSymlinkedCacheRoot() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            let targetDir = tempDir.appending(path: "target", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            let victim = targetDir.appending(path: "victim.md")
            try Data("do not delete".utf8).write(to: victim)
            let cacheDir = tempDir.appending(path: "remote-markdown", directoryHint: .isDirectory)
            try FileManager.default.createSymbolicLink(at: cacheDir, withDestinationURL: targetDir)

            RemoteMarkdownSnapshotFetcher(cacheDirectoryURL: cacheDir)
                .pruneUnreferencedSnapshots(keeping: [])

            #expect(FileManager.default.fileExists(atPath: victim.path))
        }
    }

    @Test("empty snapshot restores without quarantine")
    func emptySnapshotRestoresWithoutQuarantine() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            let snapshot = SessionSnapshot(groups: [], selectedSessionID: nil)
            try Self.write(snapshot, to: tempDir)

            let result = SessionPersistence.load()

            #expect(result.recoveryWarning == nil)
            #expect(result.store.groups.isEmpty)
            #expect(result.store.selectedSessionID == nil)
            #expect(try Self.corruptedArchives(in: tempDir).isEmpty)
            #expect(try Self.sanitizedArchives(in: tempDir).isEmpty)
        }
    }

    @Test("snapshot missing groups key is quarantined")
    func snapshotMissingGroupsKeyIsQuarantined() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            let snapshotURL = tempDir.appending(path: "session-state.json")
            try Data(#"{"schemaVersion":4}"#.utf8).write(to: snapshotURL)

            let result = SessionPersistence.load()

            guard case let .archivedSnapshot(archivedSnapshotURL, archiveError) = result.recoveryWarning?.kind else {
                Issue.record("expected archived snapshot warning for missing groups key")
                return
            }
            let archiveURL = try #require(archivedSnapshotURL)
            #expect(archiveError == nil)
            #expect(archiveURL.lastPathComponent.contains("session-state.corrupted-"))
            #expect(FileManager.default.fileExists(atPath: archiveURL.path))
            #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
        }
    }

    @Test("corrupted snapshot behavior is unchanged")
    func corruptedSnapshotBehaviorIsUnchanged() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            let snapshotURL = tempDir.appending(path: "session-state.json")
            try Data("{not-json".utf8).write(to: snapshotURL)

            let result = SessionPersistence.load()

            guard case let .archivedSnapshot(archivedSnapshotURL, archiveError) = result.recoveryWarning?.kind else {
                Issue.record("expected archived snapshot warning")
                return
            }
            let archiveURL = try #require(archivedSnapshotURL)
            #expect(archiveError == nil)
            #expect(archiveURL.lastPathComponent.contains("session-state.corrupted-"))
            #expect(FileManager.default.fileExists(atPath: archiveURL.path))
            #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
        }
    }

    @Test("zero-byte snapshot is quarantined")
    func zeroByteSnapshotIsQuarantined() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            let snapshotURL = tempDir.appending(path: "session-state.json")
            try Data().write(to: snapshotURL)

            let result = SessionPersistence.load()

            guard case let .archivedSnapshot(archivedSnapshotURL, archiveError) = result.recoveryWarning?.kind else {
                Issue.record("expected archived snapshot warning for zero-byte snapshot")
                return
            }
            let archiveURL = try #require(archivedSnapshotURL)
            #expect(archiveError == nil)
            #expect(archiveURL.lastPathComponent.contains("session-state.corrupted-"))
            #expect(FileManager.default.fileExists(atPath: archiveURL.path))
            #expect((try Data(contentsOf: archiveURL)).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
        }
    }

    @Test("corrupted-snapshot quarantine archives are pruned to a retention bound")
    func corruptedArchivesArePruned() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            let snapshotURL = tempDir.appending(path: "session-state.json")
            // Each load() quarantines the snapshot; repeat well past the cap and
            // confirm the archives don't accumulate unbounded.
            for _ in 0..<(SessionPersistence.maxQuarantineArchives + 5) {
                try Data("{not-json".utf8).write(to: snapshotURL)
                _ = SessionPersistence.load()
            }

            let archives = try Self.corruptedArchives(in: tempDir)
            #expect(archives.count == SessionPersistence.maxQuarantineArchives)
        }
    }

    @Test("nesting-depth scan counts brackets and skips string contents")
    func nestingDepthScanCountsAndSkipsStrings() {
        #expect(SessionPersistence.maxJSONNestingDepth(in: Data("{}".utf8)) == 1)
        #expect(SessionPersistence.maxJSONNestingDepth(in: Data("[[[]]]".utf8)) == 3)
        #expect(SessionPersistence.maxJSONNestingDepth(in: Data("{\"a\":[{\"b\":1}]}".utf8)) == 3)
        // Braces inside a string value must NOT inflate the depth, even escaped
        // quotes — a working directory like "~/a{b" is legitimate.
        #expect(SessionPersistence.maxJSONNestingDepth(in: Data("{\"t\":\"{{{[[[\"}".utf8)) == 1)
        #expect(SessionPersistence.maxJSONNestingDepth(in: Data("{\"t\":\"a\\\"{b\"}".utf8)) == 1)

        let deep = String(repeating: "[", count: 600) + String(repeating: "]", count: 600)
        #expect(SessionPersistence.maxJSONNestingDepth(in: Data(deep.utf8)) == 600)
        #expect(600 > SessionPersistence.maxSnapshotNestingDepth)
    }

    @Test("a pathologically deep layout is quarantined, not crashed into")
    func deeplyNestedLayoutIsQuarantined() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            // A valid snapshot wrapper whose layout is a 1,000-deep `split`
            // chain — far past the recursion depth that overflows the stack.
            // Built as a string so encoding it doesn't itself recurse/overflow.
            let snapshotURL = tempDir.appending(path: "session-state.json")
            let json = Self.deeplyNestedSnapshotJSON(depth: 1000)
            let data = Data(json.utf8)
            // The depth guard — not the recursive decode — is what must fire here.
            #expect(
                SessionPersistence.maxJSONNestingDepth(in: data)
                    > SessionPersistence.maxSnapshotNestingDepth
            )
            try data.write(to: snapshotURL)

            // Must return (not crash) with a quarantine warning.
            let result = SessionPersistence.load()

            guard case let .archivedSnapshot(archivedSnapshotURL, archiveError) = result.recoveryWarning?.kind else {
                Issue.record("expected archived snapshot warning for over-deep layout")
                return
            }
            #expect(archiveError == nil)
            #expect(archivedSnapshotURL?.lastPathComponent.contains("session-state.corrupted-") == true)
            #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
        }
    }

    @Test("a valid layout just under the depth bound decodes without crashing")
    func subThresholdDeepLayoutDecodes() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            // 60 nested splits (~3 brackets each ≈ 180, comfortably under the
            // 256 scan bound AND the restore reducer's depth-64 cap). This proves
            // the ALLOWED side of the boundary decodes without overflowing the
            // recursive Codable walk (Codex's calibration concern) and restores
            // cleanly — no quarantine. A legitimate layout never approaches even
            // this depth; real splits top out in the single digits.
            var layout: TerminalPaneLayout = .pane(
                TerminalPane(title: "leaf", workingDirectory: "~", executionPlan: .local)
            )
            for _ in 0..<60 {
                layout = .split(TerminalSplit(
                    orientation: .vertical,
                        first: .pane(TerminalPane(title: "p", workingDirectory: "~", executionPlan: .local)),
                    second: layout
                ))
            }
            let session = TerminalSession(
                title: "deep",
                workingDirectory: "~",
                layout: layout,
                activePaneID: layout.firstPaneID
            )
            let snapshot = SessionSnapshot(
                groups: [SessionGroup(name: "main", sessions: [session])],
                selectedSessionID: session.id
            )
            let data = try JSONEncoder().encode(snapshot)
            #expect(
                SessionPersistence.maxJSONNestingDepth(in: data)
                    <= SessionPersistence.maxSnapshotNestingDepth
            )
            try data.write(to: tempDir.appending(path: "session-state.json"))

            let result = SessionPersistence.load()

            // Did NOT quarantine, and the workspace came back.
            if case .archivedSnapshot = result.recoveryWarning?.kind {
                Issue.record("a valid sub-threshold layout must not be quarantined")
            }
            #expect(result.store.groups.count == 1)
            #expect(result.store.groups.first?.sessions.count == 1)
        }
    }

    @Test("model decode-depth cap is unreachable behind the disk pre-scan")
    func modelCapIsBeyondPreScanReach() throws {
        // Lock the cross-file coupling behind the INT-524 model guard: the
        // decode-time cap `TerminalSplit.maxDecodedSplitDepth` must stay above
        // the deepest snapshot the byte pre-scan admits, so a disk snapshot
        // that survives the pre-scan always decodes fully and reaches the
        // granular use-time collapse (a single over-deep session collapses;
        // siblings survive) instead of throwing at decode and quarantining the
        // WHOLE snapshot. Proving a snapshot nested to the cap already exceeds
        // the pre-scan bound establishes that (by monotonicity, every pre-scan
        // survivor is strictly shallower than the cap). Encoding at the cap is
        // safe here: `@MainActor` runs this on the main thread's 8 MB stack.
        var layout: TerminalPaneLayout = .pane(
            TerminalPane(title: "leaf", workingDirectory: "~", executionPlan: .local)
        )
        for _ in 0..<TerminalSplit.maxDecodedSplitDepth {
            layout = .split(TerminalSplit(
                orientation: .vertical,
                    first: .pane(TerminalPane(title: "p", workingDirectory: "~", executionPlan: .local)),
                second: layout
            ))
        }
        let session = TerminalSession(
            title: "deep",
            workingDirectory: "~",
            layout: layout,
            activePaneID: layout.firstPaneID
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "main", sessions: [session])],
            selectedSessionID: session.id
        )
        let data = try JSONEncoder().encode(snapshot)
        #expect(
            SessionPersistence.maxJSONNestingDepth(in: data)
                > SessionPersistence.maxSnapshotNestingDepth
        )
    }

    private static func deeplyNestedSnapshotJSON(depth: Int) -> String {
        func pane() -> String {
            "{\"pane\":{\"id\":\"\(UUID().uuidString)\",\"title\":\"p\","
                + "\"workingDirectory\":\"~\",\"agentKind\":\"shell\","
                + "\"agentExecutionState\":\"idle\",\"unreadNotificationCount\":0}}"
        }
        var layout = pane()
        for _ in 0..<depth {
            layout = "{\"split\":{\"id\":\"\(UUID().uuidString)\",\"orientation\":\"vertical\","
                + "\"firstFraction\":0.5,\"first\":\(pane()),\"second\":\(layout)}}"
        }
        let sessionID = UUID().uuidString
        return "{\"schemaVersion\":2,\"groups\":[{\"id\":\"\(UUID().uuidString)\","
            + "\"name\":\"g\",\"sessions\":[{\"id\":\"\(sessionID)\",\"title\":\"t\","
            + "\"workingDirectory\":\"~\",\"isTitleUserEdited\":false,"
            + "\"layout\":\(layout),\"activePaneID\":\"\(UUID().uuidString)\"}]}],"
            + "\"selectedSessionID\":\"\(sessionID)\"}"
    }

    private static func withTemporarySupportDirectory(
        _ operation: (URL) throws -> Void
    ) throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "awesomux-session-persistence-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try SessionPersistence.withTemporarySupportDirectory(tempDir) {
            try operation(tempDir)
        }
    }

    @discardableResult
    private static func write(
        _ snapshot: SessionSnapshot,
        to tempDir: URL,
        url: URL? = nil
    ) throws -> Data {
        let data = try JSONEncoder().encode(snapshot)
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        try data.write(to: url ?? tempDir.appending(path: "session-state.json"))
        return data
    }

    private static func sanitizedArchives(in tempDir: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("session-state.sanitized-")
                && $0.pathExtension == "json"
        }
    }

    private static func corruptedArchives(in tempDir: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("session-state.corrupted-")
                && $0.pathExtension == "json"
        }
    }

    private static func snapshot(groupName: String) -> SessionSnapshot {
        let pane = TerminalPane(title: "shell", workingDirectory: "~", executionPlan: .local)
        let session = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle,
            layout: .pane(pane),
            activePaneID: pane.id
        )
        return SessionSnapshot(
            groups: [SessionGroup(name: groupName, sessions: [session])],
            selectedSessionID: session.id
        )
    }
}
