import AwesoMuxBridgeProtocol
import AwesoMuxTestSupport
import Foundation
import Testing

@testable import AwesoMuxCore
@testable import awesoMux

/// The watcher-to-cache wiring, on real files. `AgentTranscriptOpenerTests`
/// proves the refresh seam re-reads appended bytes; this proves an append the
/// test never announces reaches the cache file on its own.
///
/// Real vnode events, so this suite uses bounded waits and belongs to the
/// `timing` shard in `script/test.sh` (issue #162).
@MainActor
@Suite("Agent transcript live refresh watch", .serialized)
struct AgentTranscriptLiveRefreshWatchTests {
    private static let sessionID = "9f1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d"
    private static let turnA =
        #"{"type":"user","cwd":"/tmp/repo","message":{"content":"opening turn"}}"#
    private static let turnB =
        #"{"type":"assistant","cwd":"/tmp/repo","message":{"content":"later turn"}}"#

    @Test("appending to the source transcript rewrites the cache file")
    func appendRewritesTheCacheFile() async throws {
        let root = try TemporaryDirectory(prefix: "awesomux-live-refresh-watch")
        defer { withExtendedLifetime(root) {} }
        let configHome = root.url.appending(path: "claude", directoryHint: .isDirectory)
        let projects = configHome.appending(path: "projects/-tmp-repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let source = projects.appending(path: "\(Self.sessionID).jsonl")
        try Data("\(Self.turnA)\n".utf8).write(to: source)

        let store = AgentTranscriptStore(
            cacheDirectoryURL: root.url.appending(path: "cache", directoryHint: .isDirectory)
        )
        let cacheURL = store.fileURL(agentKind: .claudeCode, sessionID: Self.sessionID)
        let identity = try #require(
            AgentTranscriptIdentity(agentKind: .claudeCode, sessionID: Self.sessionID)
        )

        let loop = AgentTranscriptLiveRefresh(
            identity: identity,
            configHome: configHome,
            gate: AgentTranscriptRenderGate(),
            pinned: nil,
            store: store,
            onPin: { _ in }
        )
        let task = Task { await loop.run() }
        defer {
            task.cancel()
        }

        func cache() -> String? { try? String(contentsOf: cacheURL, encoding: .utf8) }

        #expect(
            await waitUntilEventually { cache()?.contains("opening turn") == true },
            "the catch-up render should populate the cache slot"
        )
        // `!= true` would also pass on a missing cache file, which is the one
        // outcome this line is supposed to have already ruled out.
        #expect(cache()?.contains("later turn") == false)

        // In-place append, which is how a provider extends a session log — and
        // the case the pinned read handle cannot see without a fresh open.
        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(Self.turnB)\n".utf8))
        try handle.close()

        #expect(
            await waitUntilEventually { cache()?.contains("later turn") == true },
            "the watcher must drive a re-render into the cache file with no further prompting"
        )

        task.cancel()
        await task.value
    }

    @Test("recreating a vanished source re-pins and resumes the cache")
    func recreateSourceResumesTheCache() async throws {
        let root = try TemporaryDirectory(prefix: "awesomux-live-refresh-recreate")
        defer { withExtendedLifetime(root) {} }
        let configHome = root.url.appending(path: "claude", directoryHint: .isDirectory)
        let projects = configHome.appending(path: "projects/-tmp-repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let source = projects.appending(path: "\(Self.sessionID).jsonl")
        try Data("\(Self.turnA)\n".utf8).write(to: source)

        let store = AgentTranscriptStore(
            cacheDirectoryURL: root.url.appending(path: "cache", directoryHint: .isDirectory)
        )
        let cacheURL = store.fileURL(agentKind: .claudeCode, sessionID: Self.sessionID)
        let identity = try #require(
            AgentTranscriptIdentity(agentKind: .claudeCode, sessionID: Self.sessionID)
        )
        let loop = AgentTranscriptLiveRefresh(
            identity: identity,
            configHome: configHome,
            gate: AgentTranscriptRenderGate(),
            pinned: nil,
            store: store,
            onPin: { _ in }
        )
        let task = Task { await loop.run() }
        defer { task.cancel() }

        func cache() -> String? { try? String(contentsOf: cacheURL, encoding: .utf8) }
        #expect(await waitUntilEventually { cache()?.contains("opening turn") == true })

        try FileManager.default.removeItem(at: source)
        // The exact-file watcher first completes its bounded missing-inode
        // handling; recovery then watches this still-present session directory.
        try await Task.sleep(for: .milliseconds(500))
        try Data("\(Self.turnA)\n\(Self.turnB)\n".utf8).write(to: source)

        #expect(
            await waitUntilEventually(deadline: .seconds(10)) {
                cache()?.contains("later turn") == true
            },
            "a directory vnode event must drive exact-identity discovery and resume rendering"
        )

        task.cancel()
        await task.value
    }
}
