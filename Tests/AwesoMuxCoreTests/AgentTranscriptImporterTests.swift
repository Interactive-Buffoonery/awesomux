import AwesoMuxBridgeProtocol
import Foundation
import SecureFileIO
import Testing

@testable import AwesoMuxCore

@Suite
struct AgentTranscriptImporterTests {
    private static let sessionA = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    private static let sessionB = "9a8b7c6d-5e4f-4321-9876-543210fedcba"

    @Test
    func transcriptSearchRootUsesTheProviderLayout() {
        let configHome = URL(fileURLWithPath: "/tmp/provider-home", isDirectory: true)

        #expect(
            AgentTranscriptImporter.transcriptSearchRoot(
                agentKind: .claudeCode,
                configHome: configHome
            ) == configHome.appending(path: "projects", directoryHint: .isDirectory)
        )
        for provider: AgentKind in [.codex, .pi] {
            #expect(
                AgentTranscriptImporter.transcriptSearchRoot(
                    agentKind: provider,
                    configHome: configHome
                ) == configHome.appending(path: "sessions", directoryHint: .isDirectory)
            )
        }
        for unsupported: AgentKind in [.openCode, .grok, .shell] {
            #expect(
                AgentTranscriptImporter.transcriptSearchRoot(
                    agentKind: unsupported,
                    configHome: configHome
                ) == nil
            )
        }
    }

    @Test
    func opensClaudeTranscriptByExactSessionID() throws {
        let fixture = try Fixture(provider: .claudeCode)
        defer { fixture.remove() }
        let expected = try fixture.write(
            "projects/-tmp-project/\(Self.sessionA).jsonl",
            #"{"type":"user","message":{"content":"hello"}}"#
        )

        let transcript = try fixture.open(sessionID: Self.sessionA).get()

        #expect(transcript.sessionID == Self.sessionA)
        #expect(transcript.resolvedURL == expected)
    }

    @Test
    func opensCodexTranscriptByExactSessionID() throws {
        let fixture = try Fixture(provider: .codex)
        defer { fixture.remove() }
        let expected = try fixture.write(
            "sessions/2026/08/16/rollout-2026-08-16T12-00-00-\(Self.sessionA).jsonl",
            #"{"type":"response_item","payload":{"type":"message"}}"#
        )

        #expect(try fixture.open(sessionID: Self.sessionA).get().resolvedURL == expected)
    }

    @Test
    func opensPiTranscriptByExactSessionID() throws {
        let fixture = try Fixture(provider: .pi)
        defer { fixture.remove() }
        let expected = try fixture.write(
            "sessions/2026-08-16T12-00-00_\(Self.sessionA).jsonl",
            #"{"type":"message","message":{"role":"user","content":"hello"}}"#
        )

        #expect(try fixture.open(sessionID: Self.sessionA).get().resolvedURL == expected)
    }

    @Test
    func piSuffixMatchDoesNotTreatALongerIdAsAShorterOne() throws {
        let fixture = try Fixture(provider: .pi)
        defer { fixture.remove() }
        let expected = try fixture.write(
            "sessions/2026-08-16T12-00-00_my_foo.jsonl",
            #"{"type":"message","message":{"role":"user","content":"hello"}}"#
        )

        #expect(fixture.failure(fixture.open(sessionID: "foo")) == .notFound)
        #expect(try fixture.open(sessionID: "my_foo").get().resolvedURL == expected)
    }

    @Test
    func canonicalizesUUIDBeforeFilenameLookup() throws {
        let fixture = try Fixture(provider: .claudeCode)
        defer { fixture.remove() }
        _ = try fixture.write(
            "projects/p/\(Self.sessionA).jsonl",
            #"{"type":"user","message":{"content":"hello"}}"#
        )

        #expect(try fixture.open(sessionID: Self.sessionA.uppercased()).get().sessionID == Self.sessionA)
    }

    @Test
    func prefersConversationOverNewerRelocationSidecar() throws {
        let fixture = try Fixture(provider: .claudeCode)
        defer { fixture.remove() }
        let conversation = try fixture.write(
            "projects/original/\(Self.sessionA).jsonl",
            #"{"type":"user","message":{"content":"hello"}}"#
        )
        let sidecar = try fixture.write(
            "projects/relocated/\(Self.sessionA).jsonl",
            #"{"type":"ai-title","title":"newer"}"#
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)],
            ofItemAtPath: sidecar.path
        )

        #expect(try fixture.open(sessionID: Self.sessionA).get().resolvedURL == conversation)
    }

    @Test
    func prefersNewestWhenBothCandidatesContainConversation() throws {
        let fixture = try Fixture(provider: .claudeCode)
        defer { fixture.remove() }
        _ = try fixture.write(
            "projects/old/\(Self.sessionA).jsonl",
            #"{"type":"user","message":{"content":"old"}}"#
        )
        let newest = try fixture.write(
            "projects/new/\(Self.sessionA).jsonl",
            #"{"type":"assistant","message":{"content":"new"}}"#
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)],
            ofItemAtPath: newest.path
        )

        #expect(try fixture.open(sessionID: Self.sessionA).get().resolvedURL == newest)
    }

    @Test
    func missingIdentityDoesNotGuessByWorkingDirectory() throws {
        let fixture = try Fixture(provider: .claudeCode)
        defer { fixture.remove() }
        _ = try fixture.write(
            "projects/p/\(Self.sessionA).jsonl",
            #"{"type":"user","cwd":"/tmp/project"}"#
        )

        #expect(fixture.failure(fixture.open(sessionID: nil)) == .noSessionIdentity)
    }

    @Test(arguments: ["not-a-uuid", "../../../tmp/evil", "id\nrm -rf ~"])
    func invalidIdentityIsRejected(raw: String) throws {
        let fixture = try Fixture(provider: .claudeCode)
        defer { fixture.remove() }

        #expect(fixture.failure(fixture.open(sessionID: raw)) == .invalidSessionID)
    }

    @Test
    func remoteExecutionIsRejected() throws {
        let fixture = try Fixture(provider: .claudeCode)
        defer { fixture.remove() }

        let result = AgentTranscriptImporter.open(
            agentKind: .claudeCode,
            executionPlan: .ssh(
                SSHExecution(target: RemoteTarget(user: "me", host: "example.com")!)
            ),
            configHome: fixture.configHome,
            reportedSessionID: Self.sessionA
        )

        #expect(fixture.failure(result) == .remoteExecution)
    }

    @Test
    func unsupportedProviderIsRejected() throws {
        let fixture = try Fixture(provider: .claudeCode)
        defer { fixture.remove() }

        let result = AgentTranscriptImporter.open(
            agentKind: .openCode,
            executionPlan: .local,
            configHome: fixture.configHome,
            reportedSessionID: "ses_01JABC"
        )

        #expect(fixture.failure(result) == .unsupportedAgent(.openCode))
    }

    @Test
    func finalSymlinkIsRefused() throws {
        let fixture = try Fixture(provider: .claudeCode)
        defer { fixture.remove() }
        let target = try fixture.write(
            "target.jsonl",
            #"{"type":"user","message":{"content":"secret"}}"#
        )
        let link = fixture.configHome.appending(
            path: "projects/p/\(Self.sessionA).jsonl"
        )
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(fixture.failure(fixture.open(sessionID: Self.sessionA)) == .unreadable(.unreadable))
    }

    @Test
    func candidateTraversalReportsItsBound() throws {
        let fixture = try Fixture(provider: .claudeCode)
        defer { fixture.remove() }
        let root = fixture.configHome.appending(path: "projects")
        _ = try fixture.write("projects/a.jsonl", "{}")
        _ = try fixture.write("projects/b.jsonl", "{}")

        let search = AgentTranscriptImporter.transcriptCandidates(
            in: root,
            sessionID: Self.sessionA,
            provider: .claudeCode,
            fileManager: .default,
            maximumEntries: 1
        )

        #expect(search.reachedLimit)
    }

    // MARK: - Re-opening a growing transcript

    /// `reopen` exists because a `SecureFileReadHandle` can only vouch for the
    /// length it validated: the descriptor on the prior value can never see an
    /// append, however long it is held.
    @Test
    func reopenSeesBytesAppendedAfterTheFirstOpen() throws {
        let fixture = try Fixture(provider: .claudeCode)
        defer { fixture.remove() }
        let url = try fixture.write(
            "projects/p/\(Self.sessionA).jsonl",
            #"{"type":"user","message":{"content":"first"}}"#
        )
        let prior = try fixture.open(sessionID: Self.sessionA).get()
        try fixture.append(
            #"{"type":"assistant","message":{"content":"second"}}"#,
            to: url
        )

        let reopened = try AgentTranscriptImporter.reopen(prior).get()

        #expect(reopened.agentKind == prior.agentKind)
        #expect(reopened.sessionID == prior.sessionID)
        #expect(reopened.resolvedURL == prior.resolvedURL)
        #expect(reopened.handle.size > prior.handle.size)
        #expect(reopened.handle.size == UInt64(try Data(contentsOf: url).count))
    }

    @Test
    func reopenRefusesAFileOwnedByAnotherUser() throws {
        let fixture = try Fixture(provider: .claudeCode)
        defer { fixture.remove() }
        _ = try fixture.write(
            "projects/p/\(Self.sessionA).jsonl",
            #"{"type":"user","message":{"content":"first"}}"#
        )
        let prior = try fixture.open(sessionID: Self.sessionA).get()

        #expect(
            fixture.failure(AgentTranscriptImporter.reopen(prior, effectiveUID: geteuid() &+ 1))
                == .unreadable(.wrongOwner)
        )
    }

    @Test
    func reopenRefusesANonRegularFileAtTheSamePath() throws {
        let fixture = try Fixture(provider: .claudeCode)
        defer { fixture.remove() }
        let url = try fixture.write(
            "projects/p/\(Self.sessionA).jsonl",
            #"{"type":"user","message":{"content":"first"}}"#
        )
        let prior = try fixture.open(sessionID: Self.sessionA).get()

        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        #expect(fixture.failure(AgentTranscriptImporter.reopen(prior)) == .unreadable(.notRegularFile))
    }

    /// Every refresh re-runs the ingress checks against whatever inode the path
    /// names now, so a path swapped for a symlink is refused on the next tick
    /// rather than followed on the strength of the first open.
    @Test
    func reopenRefusesASymlinkedFinalComponent() throws {
        let fixture = try Fixture(provider: .claudeCode)
        defer { fixture.remove() }
        let url = try fixture.write(
            "projects/p/\(Self.sessionA).jsonl",
            #"{"type":"user","message":{"content":"first"}}"#
        )
        let decoy = try fixture.write(
            "projects/p/decoy.jsonl",
            #"{"type":"user","message":{"content":"decoy"}}"#
        )
        let prior = try fixture.open(sessionID: Self.sessionA).get()

        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: decoy)

        #expect(fixture.failure(AgentTranscriptImporter.reopen(prior)) == .unreadable(.unreadable))
    }

    /// A path is not an inode. Re-opening resolves whatever the path names now,
    /// so carrying the prior session id forward unconditionally would stamp a
    /// validated id onto a file that merely inherited the name — the same
    /// identity/content decoupling the typed seam exists to prevent, reached
    /// through a different door.
    @Test
    func reopenRefusesAReplacementInodeAtTheSamePath() throws {
        let fixture = try Fixture(provider: .claudeCode)
        defer { fixture.remove() }
        let url = try fixture.write(
            "projects/p/\(Self.sessionA).jsonl",
            #"{"type":"user","message":{"content":"first"}}"#
        )
        let prior = try fixture.open(sessionID: Self.sessionA).get()

        // An atomic replace: same path, same owner, same permissions, new inode
        // — indistinguishable from the original by every check `open` makes.
        try Data((#"{"type":"user","message":{"content":"impostor"}}"# + "\n").utf8)
            .write(to: url, options: .atomic)

        // `.notFound` rather than a security refusal: the binding is stale, not
        // hostile, and the caller's remedy is to re-run discovery. That routes
        // into the rediscover branch and re-establishes the pairing properly.
        #expect(fixture.failure(AgentTranscriptImporter.reopen(prior)) == .notFound)
    }

    private final class Fixture {
        let root: URL
        let configHome: URL
        let provider: AgentTranscriptImporter.Provider

        init(provider: AgentTranscriptImporter.Provider) throws {
            root = FileManager.default.temporaryDirectory.appending(
                path: "awesomux-transcript-importer-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            configHome = root.appending(path: "config", directoryHint: .isDirectory)
            self.provider = provider
            try FileManager.default.createDirectory(at: configHome, withIntermediateDirectories: true)
        }

        func write(_ path: String, _ contents: String) throws -> URL {
            let url = configHome.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data((contents + "\n").utf8).write(to: url)
            return try SecureFileReader.open(at: url).resolvedURL
        }

        func append(_ contents: String, to url: URL) throws {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((contents + "\n").utf8))
        }

        func open(
            sessionID: String?
        ) -> Result<AgentTranscript, AgentTranscriptUnavailable> {
            let agentKind: AgentKind =
                switch provider {
                case .claudeCode: .claudeCode
                case .codex: .codex
                case .pi: .pi
                }
            return AgentTranscriptImporter.open(
                agentKind: agentKind,
                executionPlan: .local,
                configHome: configHome,
                reportedSessionID: sessionID
            )
        }

        func failure(
            _ result: Result<AgentTranscript, AgentTranscriptUnavailable>
        ) -> AgentTranscriptUnavailable? {
            guard case let .failure(error) = result else { return nil }
            return error
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
