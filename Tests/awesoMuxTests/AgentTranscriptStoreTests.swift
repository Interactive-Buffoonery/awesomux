import AwesoMuxBridgeProtocol
import AwesoMuxTestSupport
import Foundation
import Testing

@testable import AwesoMuxCore
@testable import awesoMux

extension SessionPersistenceSerializationDomainTests {
    @MainActor
    @Suite("AgentTranscriptStore")
    struct AgentTranscriptStoreTests {
        private static let sessionID = "9F1B2C3D-4E5F-4A6B-8C9D-0E1F2A3B4C5D"

        // MARK: - Custody

        enum CachePermissionsCase: String, CaseIterable {
            case writtenTranscriptUsesOwnerOnlyPermissions
            case looseExistingCacheDirectoryIsReclamped
        }

        @Test(arguments: CachePermissionsCase.allCases)
        func cachePermissions(_ scenario: CachePermissionsCase) throws {
            switch scenario {
            case .writtenTranscriptUsesOwnerOnlyPermissions:
                try Self.withCacheDirectory { store, cacheDirectory in
                    let fileURL = try #require(
                        store.write("# transcript", agentKind: .claudeCode, sessionID: Self.sessionID)
                    )

                    #expect(try Self.permissions(of: cacheDirectory) == 0o700)
                    #expect(try Self.permissions(of: fileURL) == 0o600)
                    #expect(try String(contentsOf: fileURL, encoding: .utf8) == "# transcript")
                }
            case .looseExistingCacheDirectoryIsReclamped:
                try Self.withCacheDirectory { store, cacheDirectory in
                    // `createOwnerOnlyDirectory` no-ops on an existing directory, so
                    // without the trailing clamp a cache created by an older build (or
                    // by the user) would stay readable by every local account.
                    try FileManager.default.createDirectory(
                        at: cacheDirectory,
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o755]
                    )
                    #expect(try Self.permissions(of: cacheDirectory) == 0o755)

                    _ = try #require(
                        store.write("# transcript", agentKind: .codex, sessionID: Self.sessionID)
                    )

                    #expect(try Self.permissions(of: cacheDirectory) == 0o700)
                }
            }
        }

        enum SymlinkedCacheRootsCase: String, CaseIterable {
            case symlinkedCacheDirectoryIsRefused
            case symlinkedCacheDirectoryIsRefusedAheadOfTheSkip
        }

        @Test(arguments: SymlinkedCacheRootsCase.allCases)
        func symlinkedCacheRoots(_ scenario: SymlinkedCacheRootsCase) throws {
            switch scenario {
            case .symlinkedCacheDirectoryIsRefused:
                let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-agent-transcript")
                defer { withExtendedLifetime(temporaryDirectory) {} }
                let root = temporaryDirectory.url
                let destination = root.appending(path: "destination", directoryHint: .isDirectory)
                let link = root.appending(path: "agent-transcripts", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let planted = destination.appending(path: "planted.transcript.md")
                try Data("planted".utf8).write(to: planted)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)

                let store = AgentTranscriptStore(cacheDirectoryURL: link)
                let written = store.write("# transcript", agentKind: .claudeCode, sessionID: Self.sessionID)
                store.pruneUnreferencedImmediately(keeping: [])

                #expect(written == nil)
                // Prune must not become a delete primitive aimed wherever the link points.
                #expect(FileManager.default.fileExists(atPath: planted.path))
                #expect(
                    try FileManager.default.contentsOfDirectory(atPath: destination.path) == [
                        "planted.transcript.md"
                    ]
                )
            case .symlinkedCacheDirectoryIsRefusedAheadOfTheSkip:
                let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-agent-transcript")
                defer { withExtendedLifetime(temporaryDirectory) {} }
                let root = temporaryDirectory.url
                let destination = root.appending(path: "destination", directoryHint: .isDirectory)
                let link = root.appending(path: "agent-transcripts", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)

                // Land the slot through the real directory, so the symlinked store's
                // skip has a byte-identical, correctly-permissioned file to find.
                let honest = AgentTranscriptStore(cacheDirectoryURL: destination)
                _ = try #require(
                    honest.write(
                        "# transcript",
                        agentKind: .claudeCode,
                        sessionID: Self.sessionID,
                        skippingUnchanged: true
                    )
                )

                let throughLink = AgentTranscriptStore(cacheDirectoryURL: link)
                #expect(
                    throughLink.write(
                        "# transcript",
                        agentKind: .claudeCode,
                        sessionID: Self.sessionID,
                        skippingUnchanged: true
                    ) == nil,
                    "an unchanged slot was accepted through a symlinked cache root"
                )
            }
        }

        // MARK: - Commit ordering

        /// The backwards-movement bug, asserted where it actually lives.
        ///
        /// A caller that evaluates its supersession gate and *then* calls `write`
        /// has evaluated it under a different lock — or none — so the sequence
        /// "old render checks, old render is superseded, new render writes, old
        /// render writes" is representable and the tab moves backwards. Pinning it
        /// requires forcing exactly that interleaving: the superseded write's gate
        /// blocks until a competing write has had its chance.
        ///
        /// If the gate runs inside `cacheLock`, the competitor cannot run at all
        /// while it blocks, so it lands *after* and the newest bytes win. If the
        /// gate runs outside, the competitor lands first and is then overwritten.
        /// The two orderings produce different final bytes, which is the assertion.
        @Test("the commit gate is evaluated inside the write's own critical section")
        func commitGateIsEvaluatedUnderTheCacheLock() throws {
            try Self.withCacheDirectory { store, _ in
                let sessionID = Self.sessionID
                let gateEntered = DispatchSemaphore(value: 0)
                let competitorFinished = DispatchSemaphore(value: 0)
                let superseded = DispatchGroup()
                let competitor = DispatchGroup()

                DispatchQueue.global().async(group: superseded) {
                    _ = store.write(
                        "old",
                        agentKind: .claudeCode,
                        sessionID: sessionID,
                        shouldCommit: {
                            gateEntered.signal()
                            // Bounded: under the fixed ordering this wait can only
                            // time out, because the competitor is blocked on the
                            // very lock this closure is running under.
                            _ = competitorFinished.wait(timeout: .now() + .milliseconds(500))
                            return true
                        }
                    )
                }
                // Bounded. An unbounded wait here would hang the whole suite
                // rather than fail it if `write` ever stopped consulting the gate,
                // which is the exact regression this test exists to catch.
                let consulted = gateEntered.wait(timeout: .now() + .seconds(5))
                #expect(consulted == .success, "write never consulted its commit gate")

                DispatchQueue.global().async(group: competitor) {
                    _ = store.write("new", agentKind: .claudeCode, sessionID: sessionID)
                    competitorFinished.signal()
                }

                superseded.wait()
                competitor.wait()

                let contents = try String(
                    contentsOf: store.fileURL(agentKind: .claudeCode, sessionID: sessionID),
                    encoding: .utf8
                )
                #expect(contents == "new", "a superseded render committed on top of a newer one")
            }
        }

        /// A refused commit is not a failure: the slot still exists and is still
        /// reported, because the render that superseded this one owns its bytes.

        // MARK: - Skipping an unchanged render

        /// The skip has to be a statement about the file, not about this process's
        /// memory of it. An external prune between two refreshes would otherwise
        /// leave the tab pointing at nothing for the rest of the session.
        @Test("an unchanged render still rewrites a slot that was pruned underneath it")
        func skippingUnchangedRestoresAPrunedSlot() throws {
            try Self.withCacheDirectory { store, _ in
                let fileURL = try #require(
                    store.write(
                        "# transcript",
                        agentKind: .claudeCode,
                        sessionID: Self.sessionID,
                        skippingUnchanged: true
                    )
                )
                try FileManager.default.removeItem(at: fileURL)

                _ = store.write(
                    "# transcript",
                    agentKind: .claudeCode,
                    sessionID: Self.sessionID,
                    skippingUnchanged: true
                )

                #expect(try String(contentsOf: fileURL, encoding: .utf8) == "# transcript")
            }
        }

        /// The skip is a read, and a read of this path is exactly as sensitive as
        /// a write to it. `SecureFileReader`'s `.rejectFinalComponent` policy
        /// deliberately resolves the PARENT with realpath, so it refuses only a
        /// symlinked slot name and happily reads *through* a symlinked cache root —
        /// which is the custody check the write path gets from
        /// `validatedOwnerOnlyDirectory` and the skip would otherwise never reach.

        /// A slot holding the right bytes at the wrong mode is not a slot to skip.
        /// This file is a plaintext copy of the session, so a `0o644` left by an
        /// older build or by the user would otherwise stay world-readable for as
        /// long as its content stopped changing — which, for a session that has
        /// ended, is forever.
        ///
        /// Rewritten rather than refused: `writeOwnerOnlyFile` renames a fresh
        /// `0o600` temp into place, so the ordinary path repairs the mode, whereas
        /// refusing would fail the refresh and blank a tab over a permission bit
        /// this process can fix.
        @Test("an unchanged slot left group-readable is rewritten rather than skipped")
        func skippingUnchangedRewritesALooseSlot() throws {
            try Self.withCacheDirectory { store, _ in
                let fileURL = try #require(
                    store.write(
                        "# transcript",
                        agentKind: .claudeCode,
                        sessionID: Self.sessionID,
                        skippingUnchanged: true
                    )
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: fileURL.path
                )
                let inode = try Self.inode(of: fileURL)

                _ = try #require(
                    store.write(
                        "# transcript",
                        agentKind: .claudeCode,
                        sessionID: Self.sessionID,
                        skippingUnchanged: true
                    )
                )

                #expect(try Self.permissions(of: fileURL) == 0o600)
                #expect(
                    try Self.inode(of: fileURL) != inode,
                    "the loose slot was skipped as unchanged instead of being rewritten"
                )
                #expect(try String(contentsOf: fileURL, encoding: .utf8) == "# transcript")
            }
        }

        // MARK: - Naming

        @Test("re-rendering the same session replaces the same path")
        func reRenderingSameSessionReusesThePath() throws {
            try Self.withCacheDirectory { store, cacheDirectory in
                let first = try #require(
                    store.write("first", agentKind: .claudeCode, sessionID: Self.sessionID)
                )
                let second = try #require(
                    store.write("second", agentKind: .claudeCode, sessionID: Self.sessionID)
                )

                // A per-render unique path would leave the open tab pointing at the
                // stale file and orphan one copy per refresh.
                #expect(first == second)
                #expect(try String(contentsOf: second, encoding: .utf8) == "second")
                #expect(
                    try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path).count == 1
                )
                #expect(try Self.permissions(of: second) == 0o600)
            }
        }

        // MARK: - Pruning

        enum PruneAuthoredAndForeignFilesCase: String, CaseIterable {
            case pruneKeepsTranscriptWrittenAfterKeepSetCapture
            case pruneCollectsForeignFiles
        }

        @Test(arguments: PruneAuthoredAndForeignFilesCase.allCases)
        func pruneAuthoredAndForeignFiles(_ scenario: PruneAuthoredAndForeignFilesCase) throws {
            switch scenario {
            case .pruneKeepsTranscriptWrittenAfterKeepSetCapture:
                try Self.withCacheDirectory { store, cacheDirectory in
                    // The scheduled prune's keep-set is captured before the render
                    // lands (an empty set stands in for "captured before this write
                    // existed"), and the cache lock alone cannot refresh it: the prune
                    // could enumerate after the write and delete the file from under
                    // the freshly opened tab. The store's authored set must keep it.
                    let fileURL = try #require(
                        store.write("# transcript", agentKind: .claudeCode, sessionID: Self.sessionID)
                    )

                    store.pruneUnreferencedImmediately(keeping: [])

                    #expect(FileManager.default.fileExists(atPath: fileURL.path))
                    #expect(try String(contentsOf: fileURL, encoding: .utf8) == "# transcript")
                }
            case .pruneCollectsForeignFiles:
                try Self.withCacheDirectory { store, cacheDirectory in
                    try FileManager.default.createOwnerOnlyDirectory(at: cacheDirectory)
                    let written = try #require(
                        store.write("# transcript", agentKind: .claudeCode, sessionID: Self.sessionID)
                    )
                    // Planted out-of-band, so it has no authored-set protection: this
                    // is the previous-launch orphan the keep-set alone must answer for.
                    let orphan = cacheDirectory.appending(path: "orphan.transcript.md")
                    try Data("transcript".utf8).write(to: orphan)

                    store.pruneUnreferencedImmediately(keeping: [])

                    #expect(FileManager.default.fileExists(atPath: written.path))
                    #expect(!FileManager.default.fileExists(atPath: orphan.path))
                }
            }
        }

        @Test("prune keeps transcripts referenced by live and recently closed layouts")
        func pruneKeepsLiveAndRecentlyClosedReferences() throws {
            let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-agent-transcript")
            defer { withExtendedLifetime(temporaryDirectory) {} }
            let tempDir = temporaryDirectory.url

            try SessionPersistence.withTemporarySupportDirectory(tempDir) {
                let cacheDirectory = tempDir.appending(
                    path: AgentTranscriptStore.directoryName,
                    directoryHint: .isDirectory
                )
                // 0o700, matching the only mode production ever creates this at:
                // the read-only prune path refuses a directory left wider.
                try FileManager.default.createDirectory(
                    at: cacheDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let live = cacheDirectory.appending(path: "live.transcript.md")
                let recent = cacheDirectory.appending(path: "recent.transcript.md")
                let orphan = cacheDirectory.appending(path: "orphan.transcript.md")
                for url in [live, recent, orphan] {
                    try Data("transcript".utf8).write(to: url)
                }

                let liveTerminal = TerminalPane(
                    title: "shell",
                    workingDirectory: "~",
                    executionPlan: .local
                )
                let liveSession = TerminalSession(
                    title: "shell",
                    workingDirectory: "~",
                    layout: Self.layout(terminal: liveTerminal, documentURL: live),
                    activePaneID: liveTerminal.id
                )
                let closedTerminal = TerminalPane(
                    title: "shell",
                    workingDirectory: "~",
                    executionPlan: .local
                )
                let closed = RecentlyClosedWorkspace(
                    sessionID: UUID(),
                    title: "transcripts",
                    isTitleUserEdited: false,
                    agentKind: .shell,
                    layout: Self.layout(terminal: closedTerminal, documentURL: recent),
                    activePaneID: closedTerminal.id,
                    groupID: UUID(),
                    groupName: "ops",
                    groupRemote: nil,
                    indexInGroup: 0,
                    closedAt: Date()
                )
                let store = SessionStore(
                    restoring: SessionSnapshot(
                        groups: [SessionGroup(name: "ops", sessions: [liveSession])],
                        selectedSessionID: liveSession.id,
                        recentlyClosed: [closed]
                    )
                )

                SessionPersistence.pruneGeneratedDocumentsForTesting(keeping: store)

                #expect(FileManager.default.fileExists(atPath: live.path))
                // Reopening a recently-closed workspace restores this tab; pruning
                // against live groups alone would hand it a deleted file.
                #expect(FileManager.default.fileExists(atPath: recent.path))
                #expect(!FileManager.default.fileExists(atPath: orphan.path))
            }
        }

        // MARK: - Helpers

        private static func layout(terminal: TerminalPane, documentURL: URL) -> TerminalPaneLayout {
            let tab = DocumentPane(fileURL: documentURL, title: documentURL.lastPathComponent)
            return .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(terminal),
                    second: .documentGroup(DocumentGroup(tabs: [tab], selectedTabID: tab.id))
                )
            )
        }

        private static func permissions(of url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return try #require(attributes[.posixPermissions] as? NSNumber).intValue
        }

        private static func inode(of url: URL) throws -> UInt64 {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return try #require(attributes[.systemFileNumber] as? NSNumber).uint64Value
        }

        private static func withCacheDirectory(
            _ operation: (AgentTranscriptStore, URL) throws -> Void
        ) throws {
            let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-agent-transcript")
            defer { withExtendedLifetime(temporaryDirectory) {} }
            let cacheDirectory = temporaryDirectory.url.appending(
                path: AgentTranscriptStore.directoryName,
                directoryHint: .isDirectory
            )
            try operation(AgentTranscriptStore(cacheDirectoryURL: cacheDirectory), cacheDirectory)
        }
    }
}
