@testable import AwesoMuxCore
import AwesoMuxTestSupport
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import awesoMux

@Suite("SessionPersistence shared-state serialization", .serialized)
struct SessionPersistenceSerializationDomainTests {}

extension SessionPersistenceSerializationDomainTests {
    @MainActor
    @Suite("SessionPersistence load")
    struct SessionPersistenceLoadTests {

        enum SanitizedRestoreCase: String, CaseIterable {
            case sanitizedRestoreCopiesOriginalSnapshotBeforeCleanedSave
            case genuineV6MixedSnapshotRecoversThroughFullLoadPipeline
        }

        @Test(arguments: SanitizedRestoreCase.allCases)
        func sanitizedRestore(_ scenario: SanitizedRestoreCase) throws {
            switch scenario {
            case .sanitizedRestoreCopiesOriginalSnapshotBeforeCleanedSave:
                try Self.withTemporarySupportDirectory { tempDir in
                    let snapshot = Self.snapshot(groupName: "ops\u{202E}")
                    let originalData = try Self.write(snapshot, to: tempDir)

                    let result = SessionPersistence.load()

                    guard case let .sanitizedRestore(summary, archivedSnapshotURL, archiveError) = result.recoveryWarning?.kind else {
                        Issue.record("expected sanitized restore warning")
                        return
                    }
                    #expect(summary.groupNameAdjustments == 1)
                    #expect(result.store.groups.first?.name == "ops")
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
            case .genuineV6MixedSnapshotRecoversThroughFullLoadPipeline:
                try Self.withTemporarySupportDirectory { tempDir in
                    let cacheDir = tempDir.appending(path: "remote-markdown", directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(
                        at: cacheDir,
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                    let legacyDisplayedURL = cacheDir.appending(path: "legacy-origin-hash.md")
                    let orphanURL = cacheDir.appending(path: "orphan.md")
                    try Data("# Legacy snapshot".utf8).write(to: legacyDisplayedURL)
                    try Data("orphan".utf8).write(to: orphanURL)
                    let fixture = try String(contentsOf: Self.v6MixedSnapshotFixtureURL, encoding: .utf8)
                    let encodedLegacyURL = legacyDisplayedURL.absoluteString.replacingOccurrences(
                        of: "/",
                        with: "\\/"
                    )
                    let fixtureData = Data(
                        fixture.replacingOccurrences(
                            of: "file:\\/\\/\\/tmp\\/awesomux-v6-cache\\/remote.md",
                            with: encodedLegacyURL
                        ).utf8
                    )
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
                    #expect(remoteDocument.fileURL == legacyDisplayedURL)

                    let fetcher = RemoteMarkdownSnapshotFetcher(cacheDirectoryURL: cacheDir)
                    let migratedIdentity = try #require(remoteDocument.remoteResourceIdentity)
                    let canonicalURLs = try #require(
                        fetcher.snapshotFileURLs(for: migratedIdentity)
                    )
                    #expect(!canonicalURLs.contains(legacyDisplayedURL))
                    let references = SessionPersistence.generatedDocumentReferences(
                        keeping: result.store,
                        remoteMarkdown: fetcher
                    )
                    #expect(references.remoteMarkdownSnapshots.isSuperset(of: canonicalURLs))
                    #expect(references.remoteMarkdownSnapshots.contains(legacyDisplayedURL))
                    fetcher.pruneUnreferencedSnapshotsImmediately(
                        keeping: references.remoteMarkdownSnapshots
                    )
                    #expect(FileManager.default.fileExists(atPath: legacyDisplayedURL.path))
                    #expect(!FileManager.default.fileExists(atPath: orphanURL.path))

                    let fallbackSession = try #require(result.store.groups.last?.sessions.first)
                    guard case let .pane(fallbackPane) = fallbackSession.layout else {
                        Issue.record("expected an empty recovered document leaf to collapse to its terminal sibling")
                        return
                    }
                    #expect(fallbackPane.id == UUID(uuidString: "10000000-0000-0000-0000-000000000002"))
                }
            }
        }

        enum FileSwappedDuringLoadCase: String, CaseIterable {
            case sanitizedRestoreArchiveCopyFailureStillWarns
            case sanitizedRestoreLeavesRegularFileReplacementUntouched
            case corruptedQuarantineLeavesPostValidationReplacementUntouched
            case cleanLoadPathReplacementStaysProtected
        }

        @Test(arguments: FileSwappedDuringLoadCase.allCases)
        func fileSwappedDuringLoad(_ scenario: FileSwappedDuringLoadCase) async throws {
            switch scenario {
            case .sanitizedRestoreArchiveCopyFailureStillWarns:
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
            case .sanitizedRestoreLeavesRegularFileReplacementUntouched:
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
            case .corruptedQuarantineLeavesPostValidationReplacementUntouched:
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
            case .cleanLoadPathReplacementStaysProtected:
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
                    let fetcher = RemoteMarkdownSnapshotFetcher(cacheDirectoryURL: cacheDir)
                    let openedIdentity = ResourceIdentity(
                        location: .remote(RemoteTarget(parsing: "devbox")!),
                        path: ResourcePath(rawValue: "/repo/opened.md")
                    )
                    let replacementIdentity = ResourceIdentity(
                        location: .remote(RemoteTarget(parsing: "devbox")!),
                        path: ResourcePath(rawValue: "/repo/replacement.md")
                    )
                    let openedCacheURL = try #require(
                        fetcher.snapshotFileURLs(for: openedIdentity)?.first {
                            !RemoteMarkdownSnapshotFetcher.isFailureDocumentPath($0)
                        }
                    )
                    let replacementCacheURL = try #require(
                        fetcher.snapshotFileURLs(for: replacementIdentity)?.first {
                            !RemoteMarkdownSnapshotFetcher.isFailureDocumentPath($0)
                        }
                    )
                    try Data("opened cache".utf8).write(to: openedCacheURL)
                    try Data("replacement cache".utf8).write(to: replacementCacheURL)
                    let openedData = try Self.write(
                        Self.remoteSnapshot(
                            groupName: "opened",
                            cacheURL: openedCacheURL,
                            remotePath: "/repo/opened.md"
                        ),
                        to: tempDir
                    )
                    let replacementData = try Self.write(
                        Self.remoteSnapshot(
                            groupName: "replacement",
                            cacheURL: replacementCacheURL,
                            remotePath: "/repo/replacement.md"
                        ),
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
        }

        enum CleanLoadCase: String, CaseIterable {
            case cleanSnapshotDoesNotCreateSanitizedArchive
            case emptySnapshotRestoresWithoutQuarantine
            case snapshotAtExactByteCapLoads
            case subThresholdDeepLayoutDecodes
        }

        @Test(arguments: CleanLoadCase.allCases)
        func cleanLoad(_ scenario: CleanLoadCase) throws {
            switch scenario {
            case .cleanSnapshotDoesNotCreateSanitizedArchive:
                try Self.withTemporarySupportDirectory { tempDir in
                    try Self.write(Self.snapshot(groupName: "ops"), to: tempDir)

                    let result = SessionPersistence.load()

                    #expect(result.recoveryWarning == nil)
                    #expect(try Self.sanitizedArchives(in: tempDir).isEmpty)
                }
            case .emptySnapshotRestoresWithoutQuarantine:
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
            case .snapshotAtExactByteCapLoads:
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
            case .subThresholdDeepLayoutDecodes:
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
        }

        enum RemoteCachePruneCase: String, CaseIterable {
            case remoteMarkdownCachePrunesUnreferencedSnapshotsAfterSuccessfulLoad
            case remoteMarkdownCacheKeepsRecentlyClosedSnapshots
            case remoteMarkdownCacheKeepsDisplayedAndSiblingSlotsForLiveIdentity
            case corruptedSnapshotRecoveryLeavesRemoteMarkdownCacheUntouched
            case remoteMarkdownCachePruningRefusesSymlinkedCacheRoot
            case recoveryReplacementPrunesAgainstLiveStore
        }

        @Test(arguments: RemoteCachePruneCase.allCases)
        func remoteCachePrune(_ scenario: RemoteCachePruneCase) async throws {
            switch scenario {
            case .remoteMarkdownCachePrunesUnreferencedSnapshotsAfterSuccessfulLoad:
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
                    let identity = ResourceIdentity(
                        location: .remote(RemoteTarget(parsing: "devbox")!),
                        path: ResourcePath(rawValue: "/repo/kept.md")
                    )
                    let fetcher = RemoteMarkdownSnapshotFetcher(cacheDirectoryURL: cacheDir)
                    let kept = try #require(
                        fetcher.snapshotFileURLs(for: identity)?.first {
                            !RemoteMarkdownSnapshotFetcher.isFailureDocumentPath($0)
                        }
                    )
                    let orphan = cacheDir.appending(path: "orphan.md")
                    try Data("kept".utf8).write(to: kept)
                    try Data("orphan".utf8).write(to: orphan)

                    let terminal = TerminalPane(title: "shell", workingDirectory: "~", executionPlan: .local)
                    let doc = DocumentPane(
                        fileURL: kept,
                        title: "kept.md",
                        remoteResourceIdentity: identity
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
            case .remoteMarkdownCacheKeepsRecentlyClosedSnapshots:
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
                    let identity = ResourceIdentity(
                        location: .remote(RemoteTarget(parsing: "devbox")!),
                        path: ResourcePath(rawValue: "/repo/recent.md")
                    )
                    let fetcher = RemoteMarkdownSnapshotFetcher(cacheDirectoryURL: cacheDir)
                    let kept = try #require(
                        fetcher.snapshotFileURLs(for: identity)?.first {
                            !RemoteMarkdownSnapshotFetcher.isFailureDocumentPath($0)
                        }
                    )
                    let orphan = cacheDir.appending(path: "orphan.md")
                    try Data("recent".utf8).write(to: kept)
                    try Data("orphan".utf8).write(to: orphan)

                    let terminal = TerminalPane(title: "shell", workingDirectory: "~", executionPlan: .local)
                    let doc = DocumentPane(
                        fileURL: kept,
                        title: "recent.md",
                        remoteResourceIdentity: identity
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
            case .remoteMarkdownCacheKeepsDisplayedAndSiblingSlotsForLiveIdentity:
                try await Self.withTemporarySupportDirectoryAsync { tempDir in
                    let cacheDir = tempDir.appending(path: "remote-markdown", directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(
                        at: cacheDir,
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                    let identity = ResourceIdentity(
                        location: .remote(RemoteTarget(parsing: "devbox")!),
                        path: ResourcePath(rawValue: "/repo/README.md")
                    )
                    let fetcher = RemoteMarkdownSnapshotFetcher(cacheDirectoryURL: cacheDir)
                    let siblingURLs = try #require(fetcher.snapshotFileURLs(for: identity))
                    let failureURL = try #require(
                        siblingURLs.first(where: RemoteMarkdownSnapshotFetcher.isFailureDocumentPath)
                    )
                    let cacheURL = try #require(
                        siblingURLs.first { !RemoteMarkdownSnapshotFetcher.isFailureDocumentPath($0) }
                    )
                    let legacyDisplayedURL = cacheDir.appending(path: "legacy-display.md")
                    let orphan = cacheDir.appending(path: "orphan.md")
                    for url in [failureURL, cacheURL, legacyDisplayedURL, orphan] {
                        try Data(url.lastPathComponent.utf8).write(to: url)
                    }

                    let terminal = TerminalPane(title: "shell", workingDirectory: "~", executionPlan: .local)
                    let doc = DocumentPane(
                        fileURL: legacyDisplayedURL,
                        title: "README.md",
                        remoteResourceIdentity: identity
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
                    let store = SessionStore(
                        restoring: SessionSnapshot(
                            groups: [SessionGroup(name: "ops", sessions: [session])],
                            selectedSessionID: session.id
                        )
                    )
                    let references = SessionPersistence.generatedDocumentReferences(
                        keeping: store,
                        remoteMarkdown: fetcher
                    )

                    fetcher.pruneUnreferencedSnapshotsImmediately(
                        keeping: references.remoteMarkdownSnapshots
                    )

                    #expect(FileManager.default.fileExists(atPath: failureURL.path))
                    #expect(FileManager.default.fileExists(atPath: cacheURL.path))
                    #expect(FileManager.default.fileExists(atPath: legacyDisplayedURL.path))
                    #expect(!FileManager.default.fileExists(atPath: orphan.path))

                    let failedRefresh = RemoteMarkdownSnapshotFetcher(
                        cacheDirectoryURL: cacheDir,
                        fetchOverride: { _ in .nonZeroExit(255) }
                    )
                    let reference = try #require(RemoteMarkdownReference.make(identity: identity))
                    guard case .cached(let snapshot, _) = await failedRefresh.fetch(reference) else {
                        Issue.record("expected the retained cache slot after a failed refresh")
                        return
                    }
                    #expect(snapshot.fileURL == cacheURL)
                }
            case .corruptedSnapshotRecoveryLeavesRemoteMarkdownCacheUntouched:
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
            case .remoteMarkdownCachePruningRefusesSymlinkedCacheRoot:
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
            case .recoveryReplacementPrunesAgainstLiveStore:
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
        }

        enum CorruptInputArchivedCase: String, CaseIterable {
            case snapshotMissingGroupsKeyIsQuarantined
            case futureSchemaVersionIsQuarantined
            case corruptedSnapshotArchivesExactBytesAndKeepsLivePathProtected
            case malformedRemoteMetadataArchivesInsteadOfBecomingLocalGroup
            case zeroByteSnapshotIsQuarantined
            case nestingDepthScanCountsAndSkipsStrings
            case deeplyNestedLayoutIsQuarantined
        }

        @Test(arguments: CorruptInputArchivedCase.allCases)
        func corruptInputArchived(_ scenario: CorruptInputArchivedCase) throws {
            switch scenario {
            case .snapshotMissingGroupsKeyIsQuarantined:
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
            case .futureSchemaVersionIsQuarantined:
                try Self.withTemporarySupportDirectory { tempDir in
                    try FileManager.default.createDirectory(
                        at: tempDir,
                        withIntermediateDirectories: true
                    )
                    let snapshotURL = tempDir.appending(path: "session-state.json")
                    let futureData = Data(
                        #"{"schemaVersion":\#(SessionSnapshot.currentSchemaVersion + 1),"groups":[]}"#.utf8
                    )
                    try futureData.write(to: snapshotURL)

                    let result = SessionPersistence.load()

                    guard case let .archivedSnapshot(archivedSnapshotURL, archiveError) = result.recoveryWarning?.kind else {
                        Issue.record("expected archived snapshot warning for a future schema version")
                        return
                    }
                    let archiveURL = try #require(archivedSnapshotURL)
                    #expect(archiveError == nil)
                    #expect(try Data(contentsOf: archiveURL) == futureData)
                    #expect(try Data(contentsOf: snapshotURL) == futureData)
                }
            case .corruptedSnapshotArchivesExactBytesAndKeepsLivePathProtected:
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
            case .malformedRemoteMetadataArchivesInsteadOfBecomingLocalGroup:
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
            case .zeroByteSnapshotIsQuarantined:
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
            case .nestingDepthScanCountsAndSkipsStrings:
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
            case .deeplyNestedLayoutIsQuarantined:
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
        }

        enum RecoveryGateFlowCase: String, CaseIterable {
            case recoveryGateCancelsAlreadyScheduledWrite
            case successfulArchiveBlocksFlushUntilAcknowledged
            case blockedTerminationFlushArchivesUnsavedSession
            case acknowledgementSchedulesCatchUpSave
            case blockedSaveReportsRecoveryWarning
        }

        @Test(arguments: RecoveryGateFlowCase.allCases)
        func recoveryGateFlow(_ scenario: RecoveryGateFlowCase) async throws {
            switch scenario {
            case .recoveryGateCancelsAlreadyScheduledWrite:
                let directory = try TemporaryDirectory(prefix: "recovery-gate-cancellation")
                let scheduler = TestScheduler()
                let writeGate = AsyncGate()
                defer { writeGate.open() }
                try await SessionPersistence.withTemporarySupportDirectoryAsync(
                    directory.url,
                    sleep: { await scheduler.wait(for: $0) },
                    beforeAutomaticWrite: { await writeGate.wait() }
                ) {
                    SessionPersistence.save(
                        SessionStore(restoring: Self.snapshot(groupName: "in flight"))
                    ) { _ in Issue.record("cancelled write completed") }
                    #expect(await waitUntil { scheduler.sleeperCount == 1 })
                    scheduler.advanceOneCycle()
                    #expect(await waitUntil { writeGate.waiterCount == 1 })
                    let pendingWrite = try #require(SessionPersistence.pendingWrite)
                    #expect(!pendingWrite.isCancelled)

                    let snapshotURL = directory.url.appending(path: "session-state.json")
                    let corruptedData = Data("{not-json".utf8)
                    try corruptedData.write(to: snapshotURL)
                    let result = SessionPersistence.load()
                    #expect(result.recoveryWarning?.preventsInitialSave == true)
                    #expect(pendingWrite.isCancelled)
                    #expect(SessionPersistence.pendingWrite == nil)

                    writeGate.open()
                    await pendingWrite.value
                    #expect(try Data(contentsOf: snapshotURL) == corruptedData)
                }
            case .successfulArchiveBlocksFlushUntilAcknowledged:
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
            case .blockedTerminationFlushArchivesUnsavedSession:
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
            case .acknowledgementSchedulesCatchUpSave:
                let directory = try TemporaryDirectory(prefix: "recovery-acknowledgement")
                let scheduler = TestScheduler()
                try await SessionPersistence.withTemporarySupportDirectoryAsync(
                    directory.url, sleep: { await scheduler.wait(for: $0) }
                ) {
                    let snapshotURL = directory.url.appending(path: "session-state.json")
                    try Data("{not-json".utf8).write(to: snapshotURL)
                    let warning = try #require(SessionPersistence.load().recoveryWarning)
                    let completed = EventRecorder<Void>()
                    let acknowledged = SessionPersistence.acknowledgeRecoveryWarning(
                        warning, thenSaving: SessionStore(restoring: Self.snapshot(groupName: "acknowledged")),
                        completion: { _ in Task { await completed.record(()) } }
                    )
                    #expect(acknowledged)
                    try #require(await waitUntil { scheduler.sleeperCount == 1 })
                    scheduler.advanceOneCycle()
                    try #require(await completed.waitForCount(1, deadline: .seconds(3)))
                    let saved = try SessionSnapshot.decode(from: Data(contentsOf: snapshotURL))
                    #expect(saved.groups.map(\.name) == ["acknowledged"])
                }
            case .blockedSaveReportsRecoveryWarning:
                try Self.withTemporarySupportDirectory { tempDir in
                    let snapshotURL = tempDir.appending(path: "session-state.json")
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    let original = Data("{not-json".utf8)
                    try original.write(to: snapshotURL)
                    let store = SessionStore(restoring: Self.snapshot(groupName: "current"))
                    var completions = 0
                    for _ in 0..<2 {
                        SessionPersistence.save(store) { result in
                            if case .failure(.warningNotActive) = result { completions += 1 }
                        }
                    }
                    #expect(completions == 2)
                    let warning = try #require(SessionPersistence.activeRecoveryWarning)
                    #expect(warning.preventsInitialSave)
                    #expect(try Data(contentsOf: snapshotURL) == original)
                    #expect(try Data(contentsOf: #require(warning.archivedSnapshotURL)) == original)
                }
            }
        }

        /// A blocked flush used to be the end of the session: `.warningNotActive`
        /// went back to a `@discardableResult` call site during teardown and the
        /// state was gone. The gate must still refuse the live file, but the state
        /// has to land somewhere a user can get it back from.

        /// Launching with "Restore workspaces" off never goes through `load`, so a
        /// save afterwards — from the settings toggle, or from the store-owned title
        /// callback that no view modifier can see — overwrote whatever was on disk
        /// with no archive and no gate. The one bypass that skipped every
        /// protection at once.
        ///
        /// Drives `save` rather than the validation helper on purpose: the helper
        /// could be correct while nothing called it. `save` is where every writer
        /// actually arrives.

        /// `save` hands its captured snapshot to a detached task that cannot re-read
        /// the setting. Turning restore off left that write free to land on the
        /// snapshot the opt-out exists to preserve.

        /// Releasing the gate is not persistence. `replaceSnapshotAfterRecovery`
        /// always knew that; acknowledgement left the state waiting for whatever
        /// unrelated mutation happened to schedule a write next.

        enum PathStateAtAcknowledgementCase: String, CaseIterable {
            case deletedSnapshotCanResumeSaving0
            case deletedSnapshotCanResumeSaving1
            case deletedSnapshotCanResumeSaving2
            case danglingSymlinkKeepsRecoveryGate
            case acknowledgementKeepsWritesBlockedAfterPathReplacement
        }

        @Test(arguments: PathStateAtAcknowledgementCase.allCases)
        func pathStateAtAcknowledgement(_ scenario: PathStateAtAcknowledgementCase) async throws {
            switch scenario {
            case .deletedSnapshotCanResumeSaving0, .deletedSnapshotCanResumeSaving1, .deletedSnapshotCanResumeSaving2:
                let kind =
                    switch scenario {
                    case .deletedSnapshotCanResumeSaving0: 0
                    case .deletedSnapshotCanResumeSaving1: 1
                    default: 2
                    }
                try Self.withTemporarySupportDirectory { tempDir in
                    let snapshotURL = tempDir.appending(path: "session-state.json")
                    try Self.write(Self.snapshot(groupName: kind == 2 ? "ops\u{202E}" : "original"), to: tempDir)
                    if kind == 0 { try Data("{not-json".utf8).write(to: snapshotURL) }
                    let result = SessionPersistence.load(afterSnapshotOpen: {
                        if kind != 0 {
                            try FileManager.default.removeItem(at: snapshotURL)
                            try Data("replacement".utf8).write(to: snapshotURL, options: .atomic)
                        }
                    })
                    let warning = try #require(result.recoveryWarning)
                    #expect(SessionPersistence.activeRecoveryWarning?.id == warning.id)
                    switch (kind, warning.kind) {
                    case (0, .archivedSnapshot), (1, .snapshotConflict), (2, .sanitizedRestore): break
                    default: Issue.record("unexpected recovery warning kind")
                    }
                    if kind != 0 {
                        #expect(!SessionPersistence.acknowledgeRecoveryWarning(warning, thenSaving: nil))
                        #expect(try Data(contentsOf: snapshotURL) == Data("replacement".utf8))
                    }
                    try FileManager.default.removeItem(at: snapshotURL)
                    #expect(SessionPersistence.canAcknowledgeRecoveryWarning(warning))
                    #expect(SessionPersistence.acknowledgeRecoveryWarning(warning, thenSaving: nil))
                    #expect(SessionPersistence.activeRecoveryWarning == nil)
                    let store = SessionStore(restoring: Self.snapshot(groupName: "resumed"))
                    try SessionPersistence.flush(store).get()
                    #expect(try SessionSnapshot.decode(from: Data(contentsOf: snapshotURL)).groups.map(\.name) == ["resumed"])
                }
            case .danglingSymlinkKeepsRecoveryGate:
                try Self.withTemporarySupportDirectory { tempDir in
                    let snapshotURL = tempDir.appending(path: "session-state.json")
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    try Data("{not-json".utf8).write(to: snapshotURL)
                    let warning = try #require(SessionPersistence.load().recoveryWarning)
                    try FileManager.default.removeItem(at: snapshotURL)
                    try FileManager.default.createSymbolicLink(at: snapshotURL, withDestinationURL: tempDir.appending(path: "missing"))
                    #expect(!SessionPersistence.canAcknowledgeRecoveryWarning(warning))
                    #expect(!SessionPersistence.acknowledgeRecoveryWarning(warning, thenSaving: nil))
                    #expect(SessionPersistence.activeRecoveryWarning?.id == warning.id)
                }
            case .acknowledgementKeepsWritesBlockedAfterPathReplacement:
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
        }

        enum ExplicitReplacementCase: String, CaseIterable {
            case blockedWarningCanBeExplicitlyReplacedFalse
            case blockedWarningCanBeExplicitlyReplacedTrue
            case explicitRecoveryAuthorizationReplacesUnsafePath
        }

        @Test(arguments: ExplicitReplacementCase.allCases)
        func explicitReplacement(_ scenario: ExplicitReplacementCase) async throws {
            switch scenario {
            case .blockedWarningCanBeExplicitlyReplacedFalse, .blockedWarningCanBeExplicitlyReplacedTrue:
                let sanitized = scenario == .blockedWarningCanBeExplicitlyReplacedTrue
                try await Self.withTemporarySupportDirectoryAsync { tempDir in
                    let snapshotURL = tempDir.appending(path: "session-state.json")
                    try Self.write(Self.snapshot(groupName: sanitized ? "ops\u{202E}" : "original"), to: tempDir)
                    let result = SessionPersistence.load(afterSnapshotOpen: {
                        try FileManager.default.removeItem(at: snapshotURL)
                        try Data("replacement".utf8).write(to: snapshotURL, options: .atomic)
                    })
                    let warning = try #require(result.recoveryWarning)
                    #expect(!SessionPersistence.canAcknowledgeRecoveryWarning(warning))
                    let store = SessionStore(restoring: Self.snapshot(groupName: "approved"))
                    try await SessionPersistence.replaceSnapshotAfterRecovery(
                        with: store, warning: warning, generatedDocumentPrune: { _ in }
                    ).get()
                    #expect(SessionPersistence.activeRecoveryWarning == nil)
                    #expect(try SessionSnapshot.decode(from: Data(contentsOf: snapshotURL)).groups.map(\.name) == ["approved"])
                    try SessionPersistence.flush(store).get()
                }
            case .explicitRecoveryAuthorizationReplacesUnsafePath:
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
        }

        enum UnsafeSnapshotKindsCase: String, CaseIterable {
            case finalComponentSymlinkIsRejected
            case fifoSnapshotIsRejectedWithoutBlocking
            case snapshotOneByteAboveCapIsRejected
            case writerPreservesExistingSnapshotWhenStateExceedsCap
        }

        @Test(arguments: UnsafeSnapshotKindsCase.allCases)
        func unsafeSnapshotKinds(_ scenario: UnsafeSnapshotKindsCase) throws {
            switch scenario {
            case .finalComponentSymlinkIsRejected:
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
            case .fifoSnapshotIsRejectedWithoutBlocking:
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
            case .snapshotOneByteAboveCapIsRejected:
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
            case .writerPreservesExistingSnapshotWhenStateExceedsCap:
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
        }

        enum FailedReplacementCanRetryCase: String, CaseIterable {
            case failedExplicitReplacementRetainsGateAndCanRetry
            case explicitReplacementIOFailureRetainsGate
        }

        @Test(arguments: FailedReplacementCanRetryCase.allCases)
        func failedReplacementCanRetry(_ scenario: FailedReplacementCanRetryCase) async throws {
            switch scenario {
            case .failedExplicitReplacementRetainsGateAndCanRetry:
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
            case .explicitReplacementIOFailureRetainsGate:
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
        }

        enum QuitDuringReplacementCase: String, CaseIterable {
            case terminationFlushWaitsForRecoveryReplacement
            case terminationFlushBoundsStalledRecoveryReplacement
            case terminationFlushDoesNotRevalidateDuringReplacement
        }

        @Test(arguments: QuitDuringReplacementCase.allCases)
        func quitDuringReplacement(_ scenario: QuitDuringReplacementCase) async throws {
            switch scenario {
            case .terminationFlushWaitsForRecoveryReplacement:
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
                                guard permitWriterToFinish.wait(timeout: .now() + 30) == .success else {
                                    Issue.record("Writer release did not arrive within 30 seconds")
                                    return .failure(.writeFailed)
                                }
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
                    let writerDidStart = await awaitValue(fallback: false) { continuation in
                        DispatchQueue.global().async {
                            let started = writerStarted.wait(timeout: .now() + 30) == .success
                            #expect(started)
                            continuation.resume(returning: started)
                        }
                    }
                    guard writerDidStart else {
                        permitWriterToFinish.signal()
                        _ = await replacementTask.value
                        return
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
            case .terminationFlushBoundsStalledRecoveryReplacement:
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
                                guard permitWriterToFinish.wait(timeout: .now() + 5) == .success else {
                                    Issue.record("flush did not return before the stalled-writer watchdog expired")
                                    return .failure(.writeFailed)
                                }
                                return .success(())
                            }
                        )
                    }
                    let writerDidStart = await awaitValue(fallback: false) { continuation in
                        DispatchQueue.global().async {
                            let started = writerStarted.wait(timeout: .now() + 30) == .success
                            #expect(started)
                            continuation.resume(returning: started)
                        }
                    }
                    guard writerDidStart else {
                        permitWriterToFinish.signal()
                        _ = await replacementTask.value
                        return
                    }

                    let flushResult = SessionPersistence.flush(
                        SessionStore(restoring: Self.snapshot(groupName: "quit-time state")),
                        recoveryWriteWaitTimeout: 0.01
                    )

                    guard case .failure(.writeFailed) = flushResult else {
                        Issue.record("expected a timed-out recovery write failure")
                        permitWriterToFinish.signal()
                        _ = await replacementTask.value
                        return
                    }
                    #expect(try Self.unsavedArchives(in: tempDir).isEmpty)
                    permitWriterToFinish.signal()
                    _ = await replacementTask.value
                    #expect(!FileManager.default.fileExists(atPath: tempDir.appending(path: "session-state.unsaved.incident").path))
                }
            case .terminationFlushDoesNotRevalidateDuringReplacement:
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
                                guard permitWriterToFinish.wait(timeout: .now() + 30) == .success else {
                                    Issue.record("Writer release did not arrive within 30 seconds")
                                    return .failure(.writeFailed)
                                }
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
                    let writerDidStart = await awaitValue(fallback: false) { continuation in
                        DispatchQueue.global().async {
                            let started = writerStarted.wait(timeout: .now() + 30) == .success
                            #expect(started)
                            continuation.resume(returning: started)
                        }
                    }
                    guard writerDidStart else {
                        permitWriterToFinish.signal()
                        _ = await replacementTask.value
                        return
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
        }

        /// Turning "Restore workspaces" off re-arms `hasValidatedSnapshotOnDisk`.
        /// Once the terminate path started flushing for an outstanding replacement
        /// (#334), that latch sent `flush` back through `load()`, which clears the
        /// gate on its first line and re-derives a NEW warning ID — so the
        /// completing write no longer matched, the gate transfer was skipped, and
        /// the approved replacement was reported `.warningNotActive`.

        enum ArchiveRetentionCase: String, CaseIterable {
            case corruptedArchivesArePruned
            case unsavedArchiveRetentionPreservesEarliestCapture
            case unsavedArchiveRetentionPinsCurrentIncident
        }

        @Test(arguments: ArchiveRetentionCase.allCases)
        func archiveRetention(_ scenario: ArchiveRetentionCase) async throws {
            switch scenario {
            case .corruptedArchivesArePruned:
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
            case .unsavedArchiveRetentionPreservesEarliestCapture:
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
            case .unsavedArchiveRetentionPinsCurrentIncident:
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
        }

        /// The three load-time families re-archive the same bad snapshot every
        /// relaunch, so their oldest copy is the most redundant. The quit-time
        /// family inverts that: each file is a different session, and the earliest
        /// is the one taken closest to the incident. Oldest-first eviction there
        /// deletes the most valuable copy first.

        /// A detached debounced save can complete after a quit-time flush created
        /// a newer incident marker. Its snapshot predates that incident, so its
        /// success must not drop the pin and expose the first archive to eviction.

        /// Archives on disk without any marker mean an incident that began before
        /// the marker mechanism shipped. Anchoring the newest capture there would
        /// let pruning evict the earliest one — the very capture #339 keeps.

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

        private static func remoteSnapshot(
            groupName: String,
            cacheURL: URL,
            remotePath: String
        ) -> SessionSnapshot {
            let terminal = TerminalPane(title: "shell", workingDirectory: "~", executionPlan: .local)
            let document = DocumentPane(
                fileURL: cacheURL,
                title: cacheURL.lastPathComponent,
                remoteResourceIdentity: ResourceIdentity(
                    location: .remote(RemoteTarget(parsing: "devbox")!),
                    path: ResourcePath(rawValue: remotePath)
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
}
