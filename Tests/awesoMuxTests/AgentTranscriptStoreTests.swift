import AwesoMuxBridgeProtocol
import AwesoMuxTestSupport
import Foundation
import Testing

@testable import AwesoMuxCore
@testable import awesoMux

@MainActor
@Suite("AgentTranscriptStore", .serialized)
struct AgentTranscriptStoreTests {
    private static let sessionID = "9F1B2C3D-4E5F-4A6B-8C9D-0E1F2A3B4C5D"

    // MARK: - Custody

    @Test("written transcript lands 0o600 inside a 0o700 directory")
    func writtenTranscriptUsesOwnerOnlyPermissions() throws {
        try Self.withCacheDirectory { store, cacheDirectory in
            let fileURL = try #require(
                store.write("# transcript", agentKind: .claudeCode, sessionID: Self.sessionID)
            )

            #expect(try Self.permissions(of: cacheDirectory) == 0o700)
            #expect(try Self.permissions(of: fileURL) == 0o600)
            #expect(try String(contentsOf: fileURL, encoding: .utf8) == "# transcript")
        }
    }

    @Test("an existing cache directory left group-readable is re-clamped on write")
    func looseExistingCacheDirectoryIsReclamped() throws {
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

    @Test("a symlinked cache directory is refused for both writes and prunes")
    func symlinkedCacheDirectoryIsRefused() throws {
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
    @Test("a refused commit leaves the slot alone and still reports it")
    func refusedCommitLeavesTheSlotAlone() throws {
        try Self.withCacheDirectory { store, _ in
            let first = try #require(
                store.write("first", agentKind: .claudeCode, sessionID: Self.sessionID)
            )
            let refused = store.write(
                "second",
                agentKind: .claudeCode,
                sessionID: Self.sessionID,
                shouldCommit: { false }
            )

            #expect(refused == first)
            #expect(try String(contentsOf: first, encoding: .utf8) == "first")
        }
    }

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

    @Test("an unchanged render whose bytes are still on disk skips the write")
    func skippingUnchangedSkipsWhenTheSlotAgrees() throws {
        try Self.withCacheDirectory { store, _ in
            let fileURL = try #require(
                store.write(
                    "# transcript",
                    agentKind: .claudeCode,
                    sessionID: Self.sessionID,
                    skippingUnchanged: true
                )
            )
            // The atomic write renames a fresh temp file into place, so the
            // inode is the evidence a second write happened.
            let inode = try Self.inode(of: fileURL)

            _ = store.write(
                "# transcript",
                agentKind: .claudeCode,
                sessionID: Self.sessionID,
                skippingUnchanged: true
            )

            #expect(try Self.inode(of: fileURL) == inode)
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

    @Test("cache file names are hashed, suffixed, and end in an allowed extension")
    func cacheFileNameShape() throws {
        let name = AgentTranscriptStore.cacheFileName(
            agentKind: .claudeCode,
            sessionID: Self.sessionID
        )

        #expect(name.hasSuffix(".transcript.md"))
        // The document pane opens this file only because `md` is allowed; the
        // distinct `.transcript` stem is what keeps an app-authored copy out of
        // a slot a user-content reader would hand back as the user's own file.
        #expect(DocumentURLValidator.allowedExtensions.contains("md"))
        #expect(!name.localizedCaseInsensitiveContains(Self.sessionID))
        let hash = String(name.dropLast(".transcript.md".count))
        #expect(hash.count == 32)
        #expect(hash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test("the same session always hashes to the same name, different agents do not")
    func cacheFileNameIsStableAndAgentScoped() {
        let claude = AgentTranscriptStore.cacheFileName(
            agentKind: .claudeCode,
            sessionID: Self.sessionID
        )
        let claudeAgain = AgentTranscriptStore.cacheFileName(
            agentKind: .claudeCode,
            sessionID: Self.sessionID
        )
        let codex = AgentTranscriptStore.cacheFileName(
            agentKind: .codex,
            sessionID: Self.sessionID
        )

        #expect(claude == claudeAgain)
        #expect(claude != codex)
    }

    @Test("key material is length-prefixed so field boundaries cannot be shifted")
    func cacheIdentityKeyIsLengthPrefixed() {
        #expect(
            AgentTranscriptStore.cacheIdentityKey(agentKind: .codex, sessionID: "a|b")
                == "16:agent-transcript|5:Codex|3:a|b"
        )

        // Every one of these collides with another under a naive separator
        // join; length prefixes must keep all of them distinct.
        let adversarialIDs = [
            "",
            "|",
            "a",
            "b",
            "a|b",
            "3:a|b",
            "5:Codex|1:a",
            "|1:a",
        ]
        let keys = Set(
            adversarialIDs.map {
                AgentTranscriptStore.cacheIdentityKey(agentKind: .codex, sessionID: $0)
            }
        )
        #expect(keys.count == adversarialIDs.count)

        // The agent field is length-prefixed too, so a session id cannot absorb
        // it by impersonating the boundary.
        #expect(
            AgentTranscriptStore.cacheIdentityKey(agentKind: .codex, sessionID: "x")
                != AgentTranscriptStore.cacheIdentityKey(agentKind: .claudeCode, sessionID: "x")
        )
    }

    @Test("the stable hash is deterministic and 128 bits wide")
    func stableHashIsDeterministic() {
        let hash = AgentTranscriptStore.stableHash("agent-transcript")

        #expect(hash == AgentTranscriptStore.stableHash("agent-transcript"))
        #expect(hash != AgentTranscriptStore.stableHash("agent-transcripts"))
        #expect(hash.count == 32)
    }

    // MARK: - Pruning

    @Test("a prune keeps a transcript written after the keep-set was captured")
    func pruneKeepsTranscriptWrittenAfterKeepSetCapture() throws {
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
    }

    @Test("a prune still collects files this process never wrote")
    func pruneCollectsForeignFiles() throws {
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

    @Test("the shared collector separates transcripts from remote Markdown snapshots")
    func generatedDocumentReferencesSplitByOwningCache() throws {
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-agent-transcript")
        defer { withExtendedLifetime(temporaryDirectory) {} }
        let cacheDirectory = temporaryDirectory.url.appending(
            path: AgentTranscriptStore.directoryName,
            directoryHint: .isDirectory
        )
        let transcriptURL = cacheDirectory.appending(path: "one.transcript.md")
        let snapshotURL = temporaryDirectory.url.appending(path: "remote.md")
        let userFileURL = temporaryDirectory.url.appending(path: "notes.transcript.md")

        let terminal = TerminalPane(title: "shell", workingDirectory: "~", executionPlan: .local)
        let tabs = [
            DocumentPane(fileURL: transcriptURL, title: "one.transcript.md"),
            DocumentPane(
                fileURL: snapshotURL,
                title: "remote.md",
                remoteResourceIdentity: ResourceIdentity(
                    location: .remote(RemoteTarget(parsing: "devbox")!),
                    path: ResourcePath(rawValue: "/repo/remote.md")
                )
            ),
            DocumentPane(fileURL: userFileURL, title: "notes.transcript.md"),
        ]
        let session = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(terminal),
                    second: .documentGroup(DocumentGroup(tabs: tabs, selectedTabID: tabs[0].id))
                )
            ),
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
            transcripts: AgentTranscriptStore(cacheDirectoryURL: cacheDirectory)
        )

        #expect(references.agentTranscripts == [transcriptURL])
        #expect(references.remoteMarkdownSnapshots == [snapshotURL])
        // Membership is by directory, not by name: a user's own file that
        // happens to end in `.transcript.md` is not an app-authored artifact.
        #expect(!references.agentTranscripts.contains(userFileURL))
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
