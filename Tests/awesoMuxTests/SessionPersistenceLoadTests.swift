@testable import AwesoMuxCore
import AwesoMuxTestSupport
import Darwin
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("SessionPersistence load", .serialized)
struct SessionPersistenceLoadTests {
    @Test("current valid snapshot loads unchanged")
    func currentValidSnapshotLoadsUnchanged() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            let snapshot = Self.snapshot(groupName: "current")
            try Self.write(snapshot, to: tempDir)

            let result = SessionPersistence.load()

            #expect(result.recoveryWarning == nil)
            #expect(result.store.groups.map(\.name) == ["current"])
        }
    }

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
            let permissions =
                try FileManager.default
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
            let snapshotURL = tempDir.appending(path: "session-state.json")
            try Self.write(Self.snapshot(groupName: "ops\u{202E}"), to: tempDir)
            let targetURL = tempDir.appending(path: "replacement-target.json")
            let targetData = Data("do not touch".utf8)
            try targetData.write(to: targetURL)

            let result = SessionPersistence.load(afterSnapshotOpen: {
                try FileManager.default.removeItem(at: snapshotURL)
                try FileManager.default.createSymbolicLink(
                    at: snapshotURL,
                    withDestinationURL: targetURL
                )
            })

            guard case let .sanitizedRestore(summary, archivedSnapshotURL, archiveError) = result.recoveryWarning?.kind else {
                Issue.record("expected sanitized restore warning")
                return
            }
            #expect(summary.groupNameAdjustments == 1)
            #expect(archivedSnapshotURL == nil)
            #expect(archiveError != nil)
            #expect(((try? snapshotURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink) == true)
            #expect(try Data(contentsOf: targetURL) == targetData)
        }
    }

    @Test("sanitized restore leaves a regular-file replacement untouched")
    func sanitizedRestoreLeavesRegularFileReplacementUntouched() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            let snapshotURL = tempDir.appending(path: "session-state.json")
            try Self.write(Self.snapshot(groupName: "ops\u{202E}"), to: tempDir)
            let replacementData = try JSONEncoder().encode(
                Self.snapshot(groupName: "replacement")
            )
            var didPruneRemoteMarkdown = false

            let result = SessionPersistence.load(
                afterSnapshotOpen: {
                    try FileManager.default.removeItem(at: snapshotURL)
                    try replacementData.write(to: snapshotURL)
                },
                generatedDocumentPrune: { _ in
                    didPruneRemoteMarkdown = true
                }
            )

            guard case let .sanitizedRestore(summary, archivedSnapshotURL, archiveError) = result.recoveryWarning?.kind else {
                Issue.record("expected sanitized restore warning")
                return
            }
            #expect(summary.groupNameAdjustments == 1)
            #expect(archivedSnapshotURL == nil)
            #expect(archiveError != nil)
            #expect(result.recoveryWarning?.preventsInitialSave == true)
            #expect(try Data(contentsOf: snapshotURL) == replacementData)
            #expect(!didPruneRemoteMarkdown)
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

    @Test("genuine v6 snapshot warns and archives while preserving healthy remote tabs")
    func genuineV6MixedSnapshotRecoversThroughFullLoadPipeline() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            let fixtureData = try Data(contentsOf: Self.v6MixedSnapshotFixtureURL)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try fixtureData.write(to: tempDir.appending(path: "session-state.json"))

            let result = SessionPersistence.load()

            guard
                case let .sanitizedRestore(summary, archiveURL, archiveError) =
                    result.recoveryWarning?.kind
            else {
                Issue.record("expected a visible sanitized-restore warning")
                return
            }
            #expect(summary.droppedDocumentTabs == 2)
            #expect(archiveError == nil)
            #expect(try Data(contentsOf: #require(archiveURL)) == fixtureData)
            #expect(try Self.sanitizedArchives(in: tempDir).count == 1)
            #expect(try Self.corruptedArchives(in: tempDir).isEmpty)
            #expect(result.store.groups.map(\.name) == ["mixed", "fallback"])
            #expect(result.store.selectedSessionID == UUID(uuidString: "40000000-0000-0000-0000-000000000001"))

            let mixedSession = try #require(result.store.groups.first?.sessions.first)
            guard case let .split(split) = mixedSession.layout,
                case let .documentGroup(documentGroup) = split.second
            else {
                Issue.record("expected the healthy mixed document group to survive")
                return
            }
            #expect(
                documentGroup.tabs.map(\.id) == [
                    UUID(uuidString: "20000000-0000-0000-0000-000000000001"),
                    UUID(uuidString: "20000000-0000-0000-0000-000000000002"),
                ])
            #expect(documentGroup.selectedTabID == UUID(uuidString: "20000000-0000-0000-0000-000000000001"))
            let remoteDocument = try #require(documentGroup.tabs.last)
            #expect(remoteDocument.remoteResourceIdentity?.remoteTarget?.sshDestination == "devbox")
            #expect(remoteDocument.remoteResourceIdentity?.path.rawValue == "/repo/generated:/README.md")

            let fallbackSession = try #require(result.store.groups.last?.sessions.first)
            guard case let .pane(fallbackPane) = fallbackSession.layout else {
                Issue.record("expected an empty recovered document leaf to collapse to its terminal sibling")
                return
            }
            #expect(fallbackPane.id == UUID(uuidString: "10000000-0000-0000-0000-000000000002"))
        }
    }

    @Test("typed remote markdown restores while its SSH pane is disconnected")
    func typedRemoteMarkdownRestoresWhilePaneIsDisconnected() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            let cacheDir = tempDir.appending(path: "remote-markdown", directoryHint: .isDirectory)
            // 0o700, because that is the only mode production ever creates this
            // at: the cache is made through `validatedOwnerOnlyDirectory`, and
            // the read-only prune path refuses a directory left wider.
            try FileManager.default.createDirectory(
                at: cacheDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let cachedSnapshot = cacheDir.appending(path: "offline.md")
            try Data("# Offline snapshot".utf8).write(to: cachedSnapshot)

            let target = try #require(RemoteTarget(parsing: "alice@devbox"))
            let terminal = TerminalPane(
                title: "remote shell",
                workingDirectory: "~",
                executionPlan: .ssh(SSHExecution(target: target))
            )
            let document = DocumentPane(
                fileURL: cachedSnapshot,
                title: "offline.md",
                associatedTerminalPaneID: terminal.id,
                remoteResourceIdentity: ResourceIdentity(
                    location: .remote(target),
                    path: ResourcePath(rawValue: "/repo/offline.md")
                )
            )
            let session = TerminalSession(
                title: "remote shell",
                workingDirectory: "~",
                layout: .split(
                    TerminalSplit(
                        orientation: .vertical,
                        first: .pane(terminal),
                        second: .documentGroup(
                            DocumentGroup(
                                tabs: [document],
                                selectedTabID: document.id
                            ))
                    )),
                activePaneID: terminal.id
            )
            try Self.write(
                SessionSnapshot(
                    groups: [SessionGroup(name: "remote", sessions: [session])],
                    selectedSessionID: session.id
                ),
                to: tempDir
            )

            let result = SessionPersistence.load()

            #expect(result.recoveryWarning == nil)
            let restoredSession = try #require(result.store.session(id: session.id))
            let restoredTerminal = try #require(restoredSession.layout.pane(id: terminal.id))
            #expect(restoredTerminal.executionPlan == .ssh(SSHExecution(target: target)))
            #expect(restoredTerminal.remoteHost == nil)
            #expect(restoredTerminal.remoteWorkingDirectory == nil)
            let restoredDocument = try #require(restoredSession.layout.firstDocumentGroup?.selectedTab)
            #expect(restoredDocument.remoteResourceIdentity == document.remoteResourceIdentity)
            #expect(restoredDocument.associatedTerminalPaneID == terminal.id)
            #expect(restoredDocument.fileURL == cachedSnapshot)
            #expect(FileManager.default.fileExists(atPath: cachedSnapshot.path))
        }
    }

    @Test("remote markdown cache prunes unreferenced snapshots after successful load")
    func remoteMarkdownCachePrunesUnreferencedSnapshotsAfterSuccessfulLoad() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            let cacheDir = tempDir.appending(path: "remote-markdown", directoryHint: .isDirectory)
            // 0o700, because that is the only mode production ever creates this
            // at: the cache is made through `validatedOwnerOnlyDirectory`, and
            // the read-only prune path refuses a directory left wider.
            try FileManager.default.createDirectory(
                at: cacheDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
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
                layout: .split(
                    TerminalSplit(
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
            SessionPersistence.pruneGeneratedDocumentsForTesting(keeping: result.store)

            #expect(result.recoveryWarning == nil)
            #expect(FileManager.default.fileExists(atPath: kept.path))
            #expect(!FileManager.default.fileExists(atPath: orphan.path))
        }
    }

    @Test("remote markdown cache keeps recently closed snapshots")
    func remoteMarkdownCacheKeepsRecentlyClosedSnapshots() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            let cacheDir = tempDir.appending(path: "remote-markdown", directoryHint: .isDirectory)
            // 0o700, because that is the only mode production ever creates this
            // at: the cache is made through `validatedOwnerOnlyDirectory`, and
            // the read-only prune path refuses a directory left wider.
            try FileManager.default.createDirectory(
                at: cacheDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
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
            let layout = TerminalPaneLayout.split(
                TerminalSplit(
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
            let store = SessionStore(
                restoring: SessionSnapshot(
                    groups: [SessionGroup(name: "ops", sessions: [])],
                    selectedSessionID: nil,
                    recentlyClosed: [recent]
                ))

            SessionPersistence.pruneGeneratedDocumentsForTesting(keeping: store)

            #expect(FileManager.default.fileExists(atPath: kept.path))
            #expect(!FileManager.default.fileExists(atPath: orphan.path))
        }
    }

    @Test("corrupted snapshot recovery leaves remote markdown cache untouched")
    func corruptedSnapshotRecoveryLeavesRemoteMarkdownCacheUntouched() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            let cacheDir = tempDir.appending(path: "remote-markdown", directoryHint: .isDirectory)
            // 0o700, because that is the only mode production ever creates this
            // at: the cache is made through `validatedOwnerOnlyDirectory`, and
            // the read-only prune path refuses a directory left wider.
            try FileManager.default.createDirectory(
                at: cacheDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
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
    func remoteMarkdownCachePruningRefusesSymlinkedCacheRoot() async throws {
        try await Self.withTemporarySupportDirectoryAsync { tempDir in
            let targetDir = tempDir.appending(path: "target", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            let victim = targetDir.appending(path: "victim.md")
            try Data("do not delete".utf8).write(to: victim)
            let cacheDir = tempDir.appending(path: "remote-markdown", directoryHint: .isDirectory)
            try FileManager.default.createSymbolicLink(at: cacheDir, withDestinationURL: targetDir)

            await RemoteMarkdownSnapshotFetcher(cacheDirectoryURL: cacheDir)
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
            #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
        }
    }

    @Test("corrupted snapshot archives exact bytes and keeps the live path protected")
    func corruptedSnapshotArchivesExactBytesAndKeepsLivePathProtected() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            let snapshotURL = tempDir.appending(path: "session-state.json")
            let corruptedData = Data("{not-json".utf8)
            try corruptedData.write(to: snapshotURL)

            let result = SessionPersistence.load()

            guard case let .archivedSnapshot(archivedSnapshotURL, archiveError) = result.recoveryWarning?.kind else {
                Issue.record("expected archived snapshot warning")
                return
            }
            let archiveURL = try #require(archivedSnapshotURL)
            #expect(archiveError == nil)
            #expect(archiveURL.lastPathComponent.contains("session-state.corrupted-"))
            #expect(FileManager.default.fileExists(atPath: archiveURL.path))
            #expect(try Data(contentsOf: archiveURL) == corruptedData)
            #expect(try Data(contentsOf: snapshotURL) == corruptedData)
        }
    }

    @Test("corrupted quarantine leaves a replacement made after validation untouched")
    func corruptedQuarantineLeavesPostValidationReplacementUntouched() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            let snapshotURL = tempDir.appending(path: "session-state.json")
            let corruptedData = Data("{not-json".utf8)
            try corruptedData.write(to: snapshotURL)
            let replacementData = try JSONEncoder().encode(
                Self.snapshot(groupName: "replacement")
            )

            let result = SessionPersistence.load(afterCorruptedSnapshotValidation: {
                try FileManager.default.removeItem(at: snapshotURL)
                try replacementData.write(to: snapshotURL)
            })

            guard case let .archivedSnapshot(archivedSnapshotURL, archiveError) = result.recoveryWarning?.kind else {
                Issue.record("expected archived snapshot warning")
                return
            }
            let archiveURL = try #require(archivedSnapshotURL)
            #expect(archiveError != nil)
            #expect(result.recoveryWarning?.preventsInitialSave == true)
            #expect(try Data(contentsOf: archiveURL) == corruptedData)
            #expect(try Data(contentsOf: snapshotURL) == replacementData)

            SessionPersistence.acknowledgeRecoveryWarning(
                try #require(result.recoveryWarning),
                thenSaving: nil
            )
            _ = SessionPersistence.flush(
                SessionStore(restoring: Self.snapshot(groupName: "must stay blocked"))
            )
            #expect(try Data(contentsOf: snapshotURL) == replacementData)
        }
    }

    @Test("raising the recovery gate cancels a write that is already scheduled")
    func recoveryGateCancelsAlreadyScheduledWrite() async throws {
        try await Self.withTemporarySupportDirectoryAsync { tempDir in
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            let snapshotURL = tempDir.appending(path: "session-state.json")
            let corruptedData = Data("{not-json".utf8)
            try corruptedData.write(to: snapshotURL)

            // The completion is the load-bearing assertion, not the bytes: it
            // fires only once `writeSnapshot` has run, whatever directory the
            // process-wide support-directory environment named by then. The byte
            // check alone would pass vacuously if a concurrent suite swapped
            // that environment during the wait below.
            await confirmation("no write lands on the protected snapshot", expectedCount: 0) { wrote in
                // A debounced write is already in flight when the gate goes up.
                // The guard in `save` cannot see it: that write was scheduled
                // while automatic writes were still allowed.
                SessionPersistence.save(
                    SessionStore(restoring: Self.snapshot(groupName: "in flight"))
                ) { _ in wrote() }
                let result = SessionPersistence.load()
                #expect(result.recoveryWarning?.preventsInitialSave == true)

                // Well past the debounce interval, so an uncancelled write has
                // had its chance to clobber the protected snapshot.
                try? await Task.sleep(for: SessionPersistence.debounceInterval * 3)
            }

            #expect(try Data(contentsOf: snapshotURL) == corruptedData)
        }
    }

    @Test("successful archive blocks termination flush until recovery is acknowledged")
    func successfulArchiveBlocksFlushUntilAcknowledged() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            let snapshotURL = tempDir.appending(path: "session-state.json")
            let corruptedData = Data("{not-json".utf8)
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            try corruptedData.write(to: snapshotURL)

            let protectedResult = SessionPersistence.load()
            #expect(protectedResult.recoveryWarning?.preventsInitialSave == true)

            _ = SessionPersistence.flush(
                SessionStore(restoring: Self.snapshot(groupName: "must not overwrite"))
            )
            #expect(try Data(contentsOf: snapshotURL) == corruptedData)

            SessionPersistence.acknowledgeRecoveryWarning(
                try #require(protectedResult.recoveryWarning),
                thenSaving: nil
            )

            _ = SessionPersistence.flush(
                SessionStore(restoring: Self.snapshot(groupName: "after recovery"))
            )
            let savedSnapshot = try SessionSnapshot.decode(
                from: Data(contentsOf: snapshotURL)
            )
            #expect(savedSnapshot.groups.map(\.name) == ["after recovery"])
            // Exactly one: the blocked flush above parked its state, and the
            // successful one after acknowledgement did not. A quit-time net
            // that fired on success too would make that assertion prove nothing.
            #expect(try Self.unsavedArchives(in: tempDir).count == 1)
        }
    }

    /// A blocked flush used to be the end of the session: `.warningNotActive`
    /// went back to a `@discardableResult` call site during teardown and the
    /// state was gone. The gate must still refuse the live file, but the state
    /// has to land somewhere a user can get it back from.
    @Test("a termination flush the recovery gate refuses parks the session in an archive")
    func blockedTerminationFlushArchivesUnsavedSession() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            let snapshotURL = tempDir.appending(path: "session-state.json")
            let corruptedData = Data("{not-json".utf8)
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            try corruptedData.write(to: snapshotURL)

            let protectedResult = SessionPersistence.load()
            #expect(protectedResult.recoveryWarning?.preventsInitialSave == true)

            let flushResult = SessionPersistence.flush(
                SessionStore(restoring: Self.snapshot(groupName: "unsaved at quit"))
            )

            guard case .failure(.warningNotActive) = flushResult else {
                Issue.record("expected the recovery gate to refuse the live snapshot write")
                return
            }
            // The gate's whole job: the protected bytes are untouched.
            #expect(try Data(contentsOf: snapshotURL) == corruptedData)

            // Asserted against the directory this test owns, not a recomputed
            // `supportDirectoryURL`: a concurrent suite swapping the
            // process-wide environment mid-flush then reads as a failure here
            // rather than as a pass on somebody else's write (awesomux#325).
            let archives = try Self.unsavedArchives(in: tempDir)
            #expect(archives.count == 1)
            let archiveURL = try #require(archives.first)
            let parked = try SessionSnapshot.decode(from: Data(contentsOf: archiveURL))
            #expect(parked.groups.map(\.name) == ["unsaved at quit"])
            // It mirrors the same cwds the live snapshot would, so same mode.
            let permissions =
                try FileManager.default
                .attributesOfItem(atPath: archiveURL.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.int16Value == 0o600)
        }
    }

    /// Launching with "Restore workspaces" off never goes through `load`, so a
    /// save afterwards — from the settings toggle, or from the store-owned title
    /// callback that no view modifier can see — overwrote whatever was on disk
    /// with no archive and no gate. The one bypass that skipped every
    /// protection at once.
    ///
    /// Drives `save` rather than the validation helper on purpose: the helper
    /// could be correct while nothing called it. `save` is where every writer
    /// actually arrives.
    @Test("a save with no prior load archives and protects an unreadable snapshot")
    func saveWithoutPriorLoadProtectsUnreadableSnapshot() async throws {
        try await Self.withTemporarySupportDirectoryAsync { tempDir in
            let snapshotURL = tempDir.appending(path: "session-state.json")
            let corruptedData = Data("{not-json".utf8)
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            try corruptedData.write(to: snapshotURL)

            // Deliberately no `load()`: that is precisely what launching with
            // restore disabled skips.
            try await confirmation(
                "no write lands on the never-validated snapshot",
                expectedCount: 0
            ) { wrote in
                SessionPersistence.save(
                    SessionStore(restoring: Self.snapshot(groupName: "live session"))
                ) { _ in wrote() }

                // Deterministic half, asserted before any waiting: an
                // unvalidated save must have archived the bytes it refused to
                // overwrite. Without the chokepoint check no archive exists here
                // at all, whatever the wait below goes on to observe.
                let archives = try Self.corruptedArchives(in: tempDir)
                #expect(archives.count == 1)
                let archiveURL = try #require(archives.first)
                #expect(try Data(contentsOf: archiveURL) == corruptedData)

                // Timing half: a save that scheduled instead of refusing lands
                // one debounce interval later, so the byte check below would
                // pass vacuously without this.
                try? await Task.sleep(for: SessionPersistence.debounceInterval * 3)
            }

            #expect(try Data(contentsOf: snapshotURL) == corruptedData)
        }
    }

    /// `save` hands its captured snapshot to a detached task that cannot re-read
    /// the setting. Turning restore off left that write free to land on the
    /// snapshot the opt-out exists to preserve.
    @Test("turning restore off drops a write the debouncer already captured")
    func disablingRestoreCancelsCapturedWrite() async throws {
        try await Self.withTemporarySupportDirectoryAsync { tempDir in
            let existingData = try Self.write(Self.snapshot(groupName: "opted out"), to: tempDir)
            let snapshotURL = tempDir.appending(path: "session-state.json")
            // Precondition, not scenery: a load that raised the gate would make
            // `save` refuse on its own and the assertions below would hold
            // without the cancellation ever being exercised.
            #expect(SessionPersistence.load().recoveryWarning == nil)

            await confirmation(
                "the captured write never lands",
                expectedCount: 0
            ) { wrote in
                SessionPersistence.save(
                    SessionStore(restoring: Self.snapshot(groupName: "after opt out"))
                ) { _ in wrote() }
                SessionPersistence.restoreWorkspacesDidTurnOff()
                try? await Task.sleep(for: SessionPersistence.debounceInterval * 3)
            }

            #expect(try Data(contentsOf: snapshotURL) == existingData)
        }
    }

    /// Releasing the gate is not persistence. `replaceSnapshotAfterRecovery`
    /// always knew that; acknowledgement left the state waiting for whatever
    /// unrelated mutation happened to schedule a write next.
    @Test("acknowledging a recovery warning persists the live session")
    func acknowledgementSchedulesCatchUpSave() async throws {
        try await Self.withTemporarySupportDirectoryAsync { tempDir in
            let snapshotURL = tempDir.appending(path: "session-state.json")
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            try Data("{not-json".utf8).write(to: snapshotURL)

            let protectedResult = SessionPersistence.load()
            let warning = try #require(protectedResult.recoveryWarning)

            // The completion proves a write ran at all; the decode below proves
            // it ran *here*. Neither alone is enough — a concurrent suite can
            // swap the process-wide support directory during the wait.
            await confirmation("the acknowledged state is written") { wrote in
                let acknowledged = SessionPersistence.acknowledgeRecoveryWarning(
                    warning,
                    thenSaving: SessionStore(
                        restoring: Self.snapshot(groupName: "acknowledged")
                    ),
                    completion: { _ in wrote() }
                )
                #expect(acknowledged)
                try? await Task.sleep(for: SessionPersistence.debounceInterval * 3)
            }

            let saved = try SessionSnapshot.decode(from: Data(contentsOf: snapshotURL))
            #expect(saved.groups.map(\.name) == ["acknowledged"])
        }
    }

    @Test("acknowledgement keeps writes blocked when the archived snapshot path was replaced")
    func acknowledgementKeepsWritesBlockedAfterPathReplacement() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            let snapshotURL = tempDir.appending(path: "session-state.json")
            let corruptedData = Data("{not-json".utf8)
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            try corruptedData.write(to: snapshotURL)

            let protectedResult = SessionPersistence.load()
            let warning = try #require(protectedResult.recoveryWarning)
            #expect(warning.allowsAutomaticWritesAfterAcknowledgement)

            let replacementData = try JSONEncoder().encode(
                Self.snapshot(groupName: "replacement")
            )
            try FileManager.default.removeItem(at: snapshotURL)
            try replacementData.write(to: snapshotURL)

            #expect(!SessionPersistence.acknowledgeRecoveryWarning(warning, thenSaving: nil))
            _ = SessionPersistence.flush(
                SessionStore(restoring: Self.snapshot(groupName: "must stay blocked"))
            )

            #expect(try Data(contentsOf: snapshotURL) == replacementData)
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
            #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
        }
    }

    @Test("final-component symlink is rejected without touching its target")
    func finalComponentSymlinkIsRejected() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            let targetURL = tempDir.appending(path: "target.json")
            let targetData = try JSONEncoder().encode(Self.snapshot(groupName: "target"))
            try targetData.write(to: targetURL)
            let snapshotURL = tempDir.appending(path: "session-state.json")
            try FileManager.default.createSymbolicLink(
                atPath: snapshotURL.path,
                withDestinationPath: targetURL.lastPathComponent
            )

            let result = SessionPersistence.load()

            guard case .archivedSnapshot = result.recoveryWarning?.kind else {
                Issue.record("expected unsafe snapshot warning")
                return
            }
            #expect(result.store.groups.isEmpty)
            #expect(try Data(contentsOf: targetURL) == targetData)
        }
    }

    @Test("snapshot at the exact byte cap loads")
    func snapshotAtExactByteCapLoads() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            let snapshotData = try JSONEncoder().encode(Self.snapshot(groupName: "exact cap"))
            let paddingCount = SessionPersistence.maxSnapshotBytes - snapshotData.count
            try #require(paddingCount > 0)
            var paddedData = snapshotData
            paddedData.append(Data(repeating: 0x20, count: paddingCount))
            #expect(paddedData.count == SessionPersistence.maxSnapshotBytes)
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            try paddedData.write(to: tempDir.appending(path: "session-state.json"))

            let result = SessionPersistence.load()

            #expect(result.recoveryWarning == nil)
            #expect(result.store.groups.map(\.name) == ["exact cap"])
        }
    }

    @Test("snapshot one byte above the cap is rejected")
    func snapshotOneByteAboveCapIsRejected() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            let snapshotURL = tempDir.appending(path: "session-state.json")
            _ = FileManager.default.createFile(atPath: snapshotURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: snapshotURL)
            try handle.truncate(atOffset: UInt64(SessionPersistence.maxSnapshotBytes + 1))
            try handle.close()

            let result = SessionPersistence.load()

            guard case let .archivedSnapshot(archiveURL, archiveError) = result.recoveryWarning?.kind else {
                Issue.record("expected oversized snapshot warning")
                return
            }
            #expect(result.store.groups.isEmpty)
            #expect(archiveURL == nil)
            #expect(archiveError != nil)
            #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
            #expect(try Self.corruptedArchives(in: tempDir).isEmpty)
            #expect(result.recoveryWarning?.preventsInitialSave == true)
        }
    }

    @Test("FIFO snapshot is rejected without waiting for a writer")
    func fifoSnapshotIsRejectedWithoutBlocking() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            let snapshotURL = tempDir.appending(path: "session-state.json")
            try #require(mkfifo(snapshotURL.path, 0o600) == 0)

            let result = SessionPersistence.load()

            guard case .archivedSnapshot = result.recoveryWarning?.kind else {
                Issue.record("expected unsafe snapshot warning")
                return
            }
            #expect(result.store.groups.isEmpty)
        }
    }

    @Test("clean-load path replacement stays protected through mutation and flush")
    func cleanLoadPathReplacementStaysProtected() async throws {
        try await Self.withTemporarySupportDirectoryAsync { tempDir in
            let snapshotURL = tempDir.appending(path: "session-state.json")
            let replacementURL = tempDir.appending(path: "replacement.json")
            let cacheDir = tempDir.appending(path: "remote-markdown", directoryHint: .isDirectory)
            // 0o700, because that is the only mode production ever creates this
            // at: the cache is made through `validatedOwnerOnlyDirectory`, and
            // the read-only prune path refuses a directory left wider.
            try FileManager.default.createDirectory(
                at: cacheDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let openedCacheURL = cacheDir.appending(path: "opened.md")
            let replacementCacheURL = cacheDir.appending(path: "replacement.md")
            try Data("opened cache".utf8).write(to: openedCacheURL)
            try Data("replacement cache".utf8).write(to: replacementCacheURL)
            let openedData = try Self.write(
                Self.remoteSnapshot(groupName: "opened", cacheURL: openedCacheURL),
                to: tempDir
            )
            let replacementData = try Self.write(
                Self.remoteSnapshot(groupName: "replacement", cacheURL: replacementCacheURL),
                to: tempDir,
                url: replacementURL
            )

            let result = SessionPersistence.load(
                afterSnapshotOpen: {
                    try FileManager.default.removeItem(at: snapshotURL)
                    try FileManager.default.moveItem(at: replacementURL, to: snapshotURL)
                },
                generatedDocumentPrune: { store in
                    SessionPersistence.pruneGeneratedDocumentsForTesting(keeping: store)
                }
            )

            guard case let .snapshotConflict(archiveURL, archiveError) = result.recoveryWarning?.kind else {
                Issue.record("expected snapshot conflict warning")
                return
            }
            #expect(archiveError == nil)
            #expect(try Data(contentsOf: #require(archiveURL)) == openedData)
            #expect(result.store.groups.map(\.name) == ["opened"])
            result.store.addSession(groupName: "mutated")
            _ = SessionPersistence.flush(result.store)
            #expect(try Data(contentsOf: snapshotURL) == replacementData)
            #expect(FileManager.default.fileExists(atPath: openedCacheURL.path))
            #expect(FileManager.default.fileExists(atPath: replacementCacheURL.path))

            let replacementResult = await SessionPersistence.replaceSnapshotAfterRecovery(
                with: result.store,
                warning: try #require(result.recoveryWarning),
                generatedDocumentPrune: { store in
                    SessionPersistence.pruneGeneratedDocumentsForTesting(keeping: store)
                }
            )
            try replacementResult.get()

            #expect(FileManager.default.fileExists(atPath: openedCacheURL.path))
            #expect(!FileManager.default.fileExists(atPath: replacementCacheURL.path))
        }
    }

    @Test("explicit recovery authorization replaces an unsafe snapshot path without following it")
    func explicitRecoveryAuthorizationReplacesUnsafePath() async throws {
        try await Self.withTemporarySupportDirectoryAsync { tempDir in
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            let snapshotURL = tempDir.appending(path: "session-state.json")
            let targetURL = tempDir.appending(path: "target.json")
            let targetData = Data("leave target alone".utf8)
            try targetData.write(to: targetURL)
            try FileManager.default.createSymbolicLink(
                at: snapshotURL,
                withDestinationURL: targetURL
            )

            let result = SessionPersistence.load()
            let warning = try #require(result.recoveryWarning)
            _ = SessionPersistence.flush(
                SessionStore(restoring: Self.snapshot(groupName: "blocked"))
            )
            #expect(try Data(contentsOf: targetURL) == targetData)
            #expect(((try? snapshotURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink) == true)

            try await SessionPersistence.replaceSnapshotAfterRecovery(
                with: SessionStore(restoring: Self.snapshot(groupName: "authorized")),
                warning: warning
            )
            .get()

            let savedSnapshot = try SessionSnapshot.decode(from: Data(contentsOf: snapshotURL))
            #expect(savedSnapshot.groups.map(\.name) == ["authorized"])
            #expect(try Data(contentsOf: targetURL) == targetData)
        }
    }

    @Test("failed explicit replacement retains the warning gate and can be retried")
    func failedExplicitReplacementRetainsGateAndCanRetry() async throws {
        try await Self.withTemporarySupportDirectoryAsync { tempDir in
            let snapshotURL = tempDir.appending(path: "session-state.json")
            let corruptedData = Data("{not-json".utf8)
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            try corruptedData.write(to: snapshotURL)
            let loadResult = SessionPersistence.load()
            let warning = try #require(loadResult.recoveryWarning)

            let oversizedWorkingDirectory = String(
                repeating: "x",
                count: SessionPersistence.maxSnapshotBytes
            )
            let oversizedPane = TerminalPane(
                title: "shell",
                workingDirectory: oversizedWorkingDirectory,
                executionPlan: .local
            )
            let oversizedSession = TerminalSession(
                title: "shell",
                workingDirectory: oversizedWorkingDirectory,
                layout: .pane(oversizedPane),
                activePaneID: oversizedPane.id
            )
            let oversizedStore = SessionStore(
                groups: [SessionGroup(name: "oversized", sessions: [oversizedSession])]
            )

            guard
                case .failure(.snapshotTooLarge) = await SessionPersistence.replaceSnapshotAfterRecovery(
                    with: oversizedStore,
                    warning: warning
                )
            else {
                Issue.record("expected an oversized recovery replacement failure")
                return
            }
            _ = SessionPersistence.flush(
                SessionStore(restoring: Self.snapshot(groupName: "must stay blocked"))
            )
            #expect(try Data(contentsOf: snapshotURL) == corruptedData)

            try await SessionPersistence.replaceSnapshotAfterRecovery(
                with: SessionStore(restoring: Self.snapshot(groupName: "retry")),
                warning: warning
            )
            .get()
            let savedSnapshot = try SessionSnapshot.decode(from: Data(contentsOf: snapshotURL))
            #expect(savedSnapshot.groups.map(\.name) == ["retry"])
        }
    }

    @Test("I/O failure during explicit replacement retains the warning gate")
    func explicitReplacementIOFailureRetainsGate() async throws {
        try await Self.withTemporarySupportDirectoryAsync { tempDir in
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            let snapshotURL = tempDir.appending(path: "session-state.json", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: snapshotURL,
                withIntermediateDirectories: false
            )
            let loadResult = SessionPersistence.load()
            let warning = try #require(loadResult.recoveryWarning)
            let replacementStore = SessionStore(
                restoring: Self.snapshot(groupName: "replacement")
            )

            guard
                case .failure(.writeFailed) = await SessionPersistence.replaceSnapshotAfterRecovery(
                    with: replacementStore,
                    warning: warning
                )
            else {
                Issue.record("expected an I/O recovery replacement failure")
                return
            }
            _ = SessionPersistence.flush(replacementStore)
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: snapshotURL.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)

            try FileManager.default.removeItem(at: snapshotURL)
            try await SessionPersistence.replaceSnapshotAfterRecovery(
                with: replacementStore,
                warning: warning
            )
            .get()
            let savedSnapshot = try SessionSnapshot.decode(from: Data(contentsOf: snapshotURL))
            #expect(savedSnapshot.groups.map(\.name) == ["replacement"])
        }
    }

    @Test("writer preserves the existing snapshot when encoded state exceeds the read cap")
    func writerPreservesExistingSnapshotWhenStateExceedsCap() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            let snapshotURL = tempDir.appending(path: "session-state.json")
            let existingData = try Self.write(Self.snapshot(groupName: "existing"), to: tempDir)
            let oversizedWorkingDirectory = String(
                repeating: "x",
                count: SessionPersistence.maxSnapshotBytes
            )
            let pane = TerminalPane(
                title: "shell",
                workingDirectory: oversizedWorkingDirectory,
                executionPlan: .local
            )
            let session = TerminalSession(
                title: "shell",
                workingDirectory: oversizedWorkingDirectory,
                layout: .pane(pane),
                activePaneID: pane.id
            )
            let store = SessionStore(
                groups: [SessionGroup(name: "oversized", sessions: [session])]
            )

            let writeResult = SessionPersistence.flush(store)

            #expect(try Data(contentsOf: snapshotURL) == existingData)
            guard case .failure(.snapshotTooLarge) = writeResult else {
                Issue.record("expected oversized snapshot write failure")
                return
            }
        }
    }

    @Test("termination flush waits for an explicit recovery replacement write")
    func terminationFlushWaitsForRecoveryReplacement() async throws {
        try await Self.withTemporarySupportDirectoryAsync { tempDir in
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            let snapshotURL = tempDir.appending(path: "session-state.json")
            try Data("{not-json".utf8).write(to: snapshotURL)
            let loadResult = SessionPersistence.load()
            let warning = try #require(loadResult.recoveryWarning)
            let replacementStore = SessionStore(
                restoring: Self.snapshot(groupName: "durable replacement")
            )
            let writerStarted = DispatchSemaphore(value: 0)
            let permitWriterToFinish = DispatchSemaphore(value: 0)

            let replacementTask = Task {
                await SessionPersistence.replaceSnapshotAfterRecovery(
                    with: replacementStore,
                    warning: warning,
                    snapshotWriter: { snapshot in
                        writerStarted.signal()
                        permitWriterToFinish.wait()
                        do {
                            try JSONEncoder().encode(snapshot).write(
                                to: snapshotURL,
                                options: .atomic
                            )
                            return .success(())
                        } catch {
                            return .failure(.writeFailed)
                        }
                    }
                )
            }
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    writerStarted.wait()
                    continuation.resume()
                }
            }

            _ = SessionPersistence.flush(
                SessionStore(restoring: Self.snapshot(groupName: "quit-time state")),
                whileWaitingForRecoveryWrite: {
                    permitWriterToFinish.signal()
                }
            )

            let durableSnapshot = try SessionSnapshot.decode(
                from: Data(contentsOf: snapshotURL)
            )
            #expect(durableSnapshot.groups.map(\.name) == ["quit-time state"])
            try await replacementTask.value.get()
        }
    }

    @Test("termination flush bounds a stalled recovery replacement without a second disk write")
    func terminationFlushBoundsStalledRecoveryReplacement() async throws {
        try await Self.withTemporarySupportDirectoryAsync { tempDir in
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            let snapshotURL = tempDir.appending(path: "session-state.json")
            try Data("{not-json".utf8).write(to: snapshotURL)
            let warning = try #require(SessionPersistence.load().recoveryWarning)
            let writerStarted = DispatchSemaphore(value: 0)
            let permitWriterToFinish = DispatchSemaphore(value: 0)
            let replacementTask = Task {
                await SessionPersistence.replaceSnapshotAfterRecovery(
                    with: SessionStore(restoring: Self.snapshot(groupName: "replacement")),
                    warning: warning,
                    snapshotWriter: { _ in
                        writerStarted.signal()
                        permitWriterToFinish.wait()
                        return .success(())
                    }
                )
            }
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    writerStarted.wait()
                    continuation.resume()
                }
            }

            let clock = ContinuousClock()
            let startedAt = clock.now
            let flushResult = SessionPersistence.flush(
                SessionStore(restoring: Self.snapshot(groupName: "quit-time state")),
                whileWaitingForRecoveryWrite: {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        permitWriterToFinish.signal()
                    }
                },
                recoveryWriteWaitTimeout: 0.01
            )
            let elapsed = startedAt.duration(to: clock.now)

            guard case .failure(.writeFailed) = flushResult else {
                Issue.record("expected a timed-out recovery write failure")
                permitWriterToFinish.signal()
                _ = await replacementTask.value
                return
            }
            #expect(elapsed < .milliseconds(250))
            #expect(try Self.unsavedArchives(in: tempDir).isEmpty)
            _ = await replacementTask.value
            #expect(!FileManager.default.fileExists(atPath: tempDir.appending(path: "session-state.unsaved.incident").path))
        }
    }

    /// Turning "Restore workspaces" off re-arms `hasValidatedSnapshotOnDisk`.
    /// Once the terminate path started flushing for an outstanding replacement
    /// (#334), that latch sent `flush` back through `load()`, which clears the
    /// gate on its first line and re-derives a NEW warning ID — so the
    /// completing write no longer matched, the gate transfer was skipped, and
    /// the approved replacement was reported `.warningNotActive`.
    @Test("a quit during a replacement does not revalidate the snapshot out from under it")
    func terminationFlushDoesNotRevalidateDuringReplacement() async throws {
        try await Self.withTemporarySupportDirectoryAsync { tempDir in
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            let snapshotURL = tempDir.appending(path: "session-state.json")
            try Data("{not-json".utf8).write(to: snapshotURL)
            let loadResult = SessionPersistence.load()
            let warning = try #require(loadResult.recoveryWarning)
            #expect(SessionPersistence.hasOutstandingRecoveryReplacement == false)

            let replacementStore = SessionStore(
                restoring: Self.snapshot(groupName: "durable replacement")
            )
            let writerStarted = DispatchSemaphore(value: 0)
            let permitWriterToFinish = DispatchSemaphore(value: 0)

            let replacementTask = Task {
                await SessionPersistence.replaceSnapshotAfterRecovery(
                    with: replacementStore,
                    warning: warning,
                    snapshotWriter: { snapshot in
                        writerStarted.signal()
                        permitWriterToFinish.wait()
                        do {
                            try JSONEncoder().encode(snapshot).write(
                                to: snapshotURL,
                                options: .atomic
                            )
                            return .success(())
                        } catch {
                            return .failure(.writeFailed)
                        }
                    }
                )
            }
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    writerStarted.wait()
                    continuation.resume()
                }
            }

            // The write is in flight, so the terminate path must know to flush
            // even though the next line opts out of automatic persistence.
            #expect(SessionPersistence.hasOutstandingRecoveryReplacement)
            SessionPersistence.restoreWorkspacesDidTurnOff()

            let flushResult = SessionPersistence.flush(
                SessionStore(restoring: Self.snapshot(groupName: "quit-time state")),
                whileWaitingForRecoveryWrite: {
                    permitWriterToFinish.signal()
                }
            )

            // The gate transferred rather than being replaced by a fresh
            // warning ID mid-flight, so the quit-time state reached the live
            // file instead of being parked in an archive.
            #expect(throws: Never.self) { try flushResult.get() }
            let durableSnapshot = try SessionSnapshot.decode(
                from: Data(contentsOf: snapshotURL)
            )
            #expect(durableSnapshot.groups.map(\.name) == ["quit-time state"])
            #expect(try Self.unsavedArchives(in: tempDir).isEmpty)
            try await replacementTask.value.get()
            #expect(SessionPersistence.hasOutstandingRecoveryReplacement == false)
        }
    }

    @Test("debounced save reports an oversized snapshot")
    func debouncedSaveReportsOversizedSnapshot() async throws {
        try await Self.withTemporarySupportDirectoryAsync { _ in
            let oversizedWorkingDirectory = String(
                repeating: "x",
                count: SessionPersistence.maxSnapshotBytes
            )
            let pane = TerminalPane(
                title: "shell",
                workingDirectory: oversizedWorkingDirectory,
                executionPlan: .local
            )
            let session = TerminalSession(
                title: "shell",
                workingDirectory: oversizedWorkingDirectory,
                layout: .pane(pane),
                activePaneID: pane.id
            )
            let store = SessionStore(
                groups: [SessionGroup(name: "oversized", sessions: [session])]
            )

            let writeResult = await withCheckedContinuation { continuation in
                SessionPersistence.save(store) { result in
                    continuation.resume(returning: result)
                }
            }

            guard case .failure(.snapshotTooLarge) = writeResult else {
                Issue.record("expected debounced oversized snapshot failure")
                return
            }
        }
    }

    @Test("recovery catch-up save reports an oversized newer snapshot")
    func recoveryCatchUpSaveReportsOversizedNewerSnapshot() async throws {
        try await Self.withTemporarySupportDirectoryAsync { tempDir in
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            let snapshotURL = tempDir.appending(path: "session-state.json")
            try Data("{not-json".utf8).write(to: snapshotURL)
            let loadResult = SessionPersistence.load()
            let warning = try #require(loadResult.recoveryWarning)
            let replacementStore = SessionStore(
                restoring: Self.snapshot(groupName: "durable")
            )
            let oversizedWorkingDirectory = String(
                repeating: "x",
                count: SessionPersistence.maxSnapshotBytes
            )

            let catchUpResult:
                Result<
                    Void, SessionPersistence.RecoverySnapshotReplacementError
                > = await withCheckedContinuation { continuation in
                    Task { @MainActor in
                        _ = await SessionPersistence.replaceSnapshotAfterRecovery(
                            with: replacementStore,
                            warning: warning,
                            afterSnapshotCapture: {
                                replacementStore.addSession(
                                    workingDirectory: oversizedWorkingDirectory,
                                    groupName: "newer oversized mutation"
                                )
                            },
                            catchUpSaveCompletion: { result in
                                continuation.resume(returning: result)
                            }
                        )
                    }
                }

            guard case .failure(.snapshotTooLarge) = catchUpResult else {
                Issue.record("expected oversized recovery catch-up failure")
                return
            }
            let durableSnapshot = try SessionSnapshot.decode(
                from: Data(contentsOf: snapshotURL)
            )
            #expect(durableSnapshot.groups.map(\.name) == ["durable"])
        }
    }

    @Test("recovery replacement prunes against the live catch-up store")
    func recoveryReplacementPrunesAgainstLiveStore() async throws {
        try await Self.withTemporarySupportDirectoryAsync { tempDir in
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            try Data("{not-json".utf8).write(
                to: tempDir.appending(path: "session-state.json")
            )
            let loadResult = SessionPersistence.load()
            let warning = try #require(loadResult.recoveryWarning)
            let replacementStore = SessionStore(
                restoring: Self.snapshot(groupName: "durable")
            )
            var prunedGroupNames: [String] = []

            try await SessionPersistence.replaceSnapshotAfterRecovery(
                with: replacementStore,
                warning: warning,
                afterSnapshotCapture: {
                    replacementStore.addSession(groupName: "newer mutation")
                },
                generatedDocumentPrune: { liveStore in
                    prunedGroupNames = liveStore.groups.map(\.name)
                }
            )
            .get()

            #expect(prunedGroupNames == ["durable", "newer mutation"])
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

    /// The three load-time families re-archive the same bad snapshot every
    /// relaunch, so their oldest copy is the most redundant. The quit-time
    /// family inverts that: each file is a different session, and the earliest
    /// is the one taken closest to the incident. Oldest-first eviction there
    /// deletes the most valuable copy first.
    @Test("quit-time archive retention keeps the earliest capture and thins the middle")
    func unsavedArchiveRetentionPreservesEarliestCapture() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            let snapshotURL = tempDir.appending(path: "session-state.json")
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            try Data("{not-json".utf8).write(to: snapshotURL)
            #expect(SessionPersistence.load().recoveryWarning?.preventsInitialSave == true)

            // `archiveTimestamp()` only has second resolution and these flushes
            // land inside one second, so pin each archive's creation date by
            // hand rather than trusting the sort to break real-world ties.
            // Dates are in the past, which also keeps the freshly written file
            // genuinely newest at every prune.
            let epoch = Date(timeIntervalSince1970: 1_700_000_000)
            var dated: Set<URL> = []
            let quitCount = SessionPersistence.maxQuarantineArchives + 2
            for index in 0..<quitCount {
                let flushResult = SessionPersistence.flush(
                    SessionStore(restoring: Self.snapshot(groupName: "quit \(index)"))
                )
                guard case .failure(.warningNotActive) = flushResult else {
                    Issue.record("expected the recovery gate to refuse quit \(index)")
                    return
                }
                for archive in try Self.unsavedArchives(in: tempDir) where !dated.contains(archive) {
                    try FileManager.default.setAttributes(
                        [.creationDate: epoch.addingTimeInterval(TimeInterval(index))],
                        ofItemAtPath: archive.path
                    )
                    dated.insert(archive)
                }
                if index == 0 {
                    let markerURL = tempDir.appending(path: "session-state.unsaved.incident")
                    let markerFileName = try String(contentsOf: markerURL, encoding: .utf8)
                    #expect(
                        try Self.unsavedArchives(in: tempDir).contains {
                            $0.lastPathComponent == markerFileName
                        }
                    )
                    let permissions =
                        try FileManager.default
                        .attributesOfItem(atPath: markerURL.path)[.posixPermissions] as? NSNumber
                    #expect(permissions?.int16Value == 0o600)
                }
            }

            let survivors = try Self.unsavedArchives(in: tempDir).map {
                try SessionSnapshot.decode(from: Data(contentsOf: $0)).groups.map(\.name).joined()
            }
            #expect(survivors.count == SessionPersistence.maxQuarantineArchives)
            // The pre-incident capture survives, the newest survives, and the
            // two evictions came out of the middle.
            #expect(survivors.contains("quit 0"))
            #expect(survivors.contains("quit \(quitCount - 1)"))
            #expect(!survivors.contains("quit 1"))
            #expect(!survivors.contains("quit 2"))
        }
    }

    @Test("quit-time archive retention re-anchors the pin after a successful save")
    func unsavedArchiveRetentionPinsCurrentIncident() async throws {
        try await Self.withTemporarySupportDirectoryAsync { tempDir in
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            let snapshotURL = tempDir.appending(path: "session-state.json")
            try Data("{first-incident".utf8).write(to: snapshotURL)
            let firstWarning = try #require(SessionPersistence.load().recoveryWarning)
            let epoch = Date(timeIntervalSince1970: 1_700_000_000)
            var dated: Set<URL> = []

            for index in 0..<3 {
                _ = SessionPersistence.flush(
                    SessionStore(restoring: Self.snapshot(groupName: "old incident \(index)"))
                )
                for archive in try Self.unsavedArchives(in: tempDir) where !dated.contains(archive) {
                    try FileManager.default.setAttributes(
                        [.creationDate: epoch.addingTimeInterval(TimeInterval(index))],
                        ofItemAtPath: archive.path
                    )
                    dated.insert(archive)
                }
            }

            try await SessionPersistence.replaceSnapshotAfterRecovery(
                with: SessionStore(restoring: Self.snapshot(groupName: "resolved")),
                warning: firstWarning
            ).get()
            try Data("{second-incident".utf8).write(to: snapshotURL)
            #expect(SessionPersistence.load().recoveryWarning?.preventsInitialSave == true)

            let currentIncidentCount = SessionPersistence.maxQuarantineArchives + 2
            for index in 0..<currentIncidentCount {
                _ = SessionPersistence.flush(
                    SessionStore(restoring: Self.snapshot(groupName: "current incident \(index)"))
                )
                for archive in try Self.unsavedArchives(in: tempDir) where !dated.contains(archive) {
                    try FileManager.default.setAttributes(
                        [.creationDate: epoch.addingTimeInterval(TimeInterval(100 + index))],
                        ofItemAtPath: archive.path
                    )
                    dated.insert(archive)
                }
            }

            let survivors = try Self.unsavedArchives(in: tempDir).map {
                try SessionSnapshot.decode(from: Data(contentsOf: $0)).groups.map(\.name).joined()
            }
            #expect(survivors.count == SessionPersistence.maxQuarantineArchives)
            #expect(survivors.contains("current incident 0"))
            #expect(survivors.contains("current incident \(currentIncidentCount - 1)"))
            #expect(!survivors.contains("old incident 0"))
            #expect(!survivors.contains("current incident 1"))
            #expect(!survivors.contains("current incident 2"))
        }
    }

    /// A detached debounced save can complete after a quit-time flush created
    /// a newer incident marker. Its snapshot predates that incident, so its
    /// success must not drop the pin and expose the first archive to eviction.
    @Test("a stale save success cannot clear a newer incident's marker")
    func staleSaveDoesNotClearNewerIncidentMarker() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            let snapshotURL = tempDir.appending(path: "session-state.json")
            try Data("{not-json".utf8).write(to: snapshotURL)
            #expect(SessionPersistence.load().recoveryWarning?.preventsInitialSave == true)

            _ = SessionPersistence.flush(
                SessionStore(restoring: Self.snapshot(groupName: "incident"))
            )
            let markerURL = tempDir.appending(path: "session-state.unsaved.incident")
            let anchoredFileName = try String(contentsOf: markerURL, encoding: .utf8)
            #expect(anchoredFileName.hasPrefix("session-state.unsaved-"))

            SessionPersistence.clearUnsavedIncidentAnchor(
                after: .success(()),
                resolvedSnapshotCapturedAt: .distantPast
            )
            #expect(try String(contentsOf: markerURL, encoding: .utf8) == anchoredFileName)

            // A save whose snapshot was captured after the marker was written
            // resolves the incident, and the boundary is recorded in place of
            // the anchor rather than deleting the marker outright.
            SessionPersistence.clearUnsavedIncidentAnchor(
                after: .success(()),
                resolvedSnapshotCapturedAt: Date()
            )
            let resolved = try String(contentsOf: markerURL, encoding: .utf8)
            #expect(resolved != anchoredFileName)
            #expect(!resolved.hasPrefix("session-state.unsaved-"))
        }
    }

    /// Archives on disk without any marker mean an incident that began before
    /// the marker mechanism shipped. Anchoring the newest capture there would
    /// let pruning evict the earliest one — the very capture #339 keeps.
    @Test("an incident predating the marker anchors its earliest surviving archive")
    func incidentPredatingMarkerAnchorsEarliestArchive() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            let epoch = Date(timeIntervalSince1970: 1_700_000_000)
            for index in 0..<2 {
                let legacy = tempDir.appending(
                    path: "session-state.unsaved-170000000\(index)-legacy\(index).json"
                )
                try Data("{}".utf8).write(to: legacy)
                try FileManager.default.setAttributes(
                    [.creationDate: epoch.addingTimeInterval(TimeInterval(index))],
                    ofItemAtPath: legacy.path
                )
            }
            let snapshotURL = tempDir.appending(path: "session-state.json")
            try Data("{not-json".utf8).write(to: snapshotURL)
            #expect(SessionPersistence.load().recoveryWarning?.preventsInitialSave == true)

            _ = SessionPersistence.flush(
                SessionStore(restoring: Self.snapshot(groupName: "late capture"))
            )

            let markerURL = tempDir.appending(path: "session-state.unsaved.incident")
            let anchored = try String(contentsOf: markerURL, encoding: .utf8)
            #expect(anchored == "session-state.unsaved-1700000000-legacy0.json")
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
            #expect(try Data(contentsOf: snapshotURL) == data)
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
                layout = .split(
                    TerminalSplit(
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
            layout = .split(
                TerminalSplit(
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
            layout =
                "{\"split\":{\"id\":\"\(UUID().uuidString)\",\"orientation\":\"vertical\","
                + "\"firstFraction\":0.5,\"first\":\(pane()),\"second\":\(layout)}}"
        }
        let sessionID = UUID().uuidString
        return "{\"schemaVersion\":2,\"groups\":[{\"id\":\"\(UUID().uuidString)\","
            + "\"name\":\"g\",\"sessions\":[{\"id\":\"\(sessionID)\",\"title\":\"t\","
            + "\"workingDirectory\":\"~\",\"isTitleUserEdited\":false,"
            + "\"layout\":\(layout),\"activePaneID\":\"\(UUID().uuidString)\"}]}],"
            + "\"selectedSessionID\":\"\(sessionID)\"}"
    }

    @Test("a transcript tab the store no longer recognizes is still kept by the prune")
    func declaredTranscriptProvenanceSurvivesAnUnrecognizedPath() throws {
        try Self.withTemporarySupportDirectory { tempDir in
            let store = SessionStore()
            store.addSession(groupName: "transcripts")
            let identity = try #require(
                AgentTranscriptIdentity(
                    agentKind: .claudeCode,
                    sessionID: "11111111-2222-3333-4444-555555555555"
                )
            )
            let strandedURL = tempDir.appending(path: "moved-cache/abc.transcript.md")
            let ordinaryURL = tempDir.appending(path: "notes.md")
            store.openDocumentPane(fileURL: strandedURL, agentTranscriptIdentity: identity)
            store.openDocumentPane(fileURL: ordinaryURL)

            // The store points somewhere else entirely — a moved Application
            // Support, or a cache directory that failed validation — so
            // directory membership alone would classify a live transcript tab
            // as unreferenced and delete the file it is showing.
            let elsewhere = AgentTranscriptStore(
                cacheDirectoryURL: tempDir.appending(
                    path: "agent-transcripts", directoryHint: .isDirectory)
            )
            #expect(!elsewhere.contains(strandedURL))

            let references = SessionPersistence.generatedDocumentReferences(
                keeping: store,
                transcripts: elsewhere
            )
            #expect(references.agentTranscripts == [strandedURL])
            #expect(references.remoteMarkdownSnapshots.isEmpty)
        }
    }

    private static var v6MixedSnapshotFixtureURL: URL {
        // Generated with JSONEncoder from the schema-v6 models at d432831.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/session-state-v6-mixed-documents.json")
    }

    private static func withTemporarySupportDirectory(
        _ operation: (URL) throws -> Void
    ) throws {
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-session-persistence")
        let tempDir = temporaryDirectory.url
        defer { withExtendedLifetime(temporaryDirectory) {} }

        try SessionPersistence.withTemporarySupportDirectory(tempDir) {
            try operation(tempDir)
        }
    }

    private static func withTemporarySupportDirectoryAsync(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-session-persistence")
        let tempDir = temporaryDirectory.url
        defer { withExtendedLifetime(temporaryDirectory) {} }

        try await SessionPersistence.withTemporarySupportDirectoryAsync(tempDir) {
            try await operation(tempDir)
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

    private static func unsavedArchives(in tempDir: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("session-state.unsaved-")
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

    private static func remoteSnapshot(groupName: String, cacheURL: URL) -> SessionSnapshot {
        let terminal = TerminalPane(title: "shell", workingDirectory: "~", executionPlan: .local)
        let document = DocumentPane(
            fileURL: cacheURL,
            title: cacheURL.lastPathComponent,
            remoteResourceIdentity: ResourceIdentity(
                location: .remote(RemoteTarget(parsing: "devbox")!),
                path: ResourcePath(rawValue: "/repo/\(cacheURL.lastPathComponent)")
            )
        )
        let session = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(terminal),
                    second: .documentGroup(
                        DocumentGroup(tabs: [document], selectedTabID: document.id)
                    )
                )
            ),
            activePaneID: terminal.id
        )
        return SessionSnapshot(
            groups: [SessionGroup(name: groupName, sessions: [session])],
            selectedSessionID: session.id
        )
    }
}
