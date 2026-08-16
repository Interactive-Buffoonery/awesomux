import Foundation
import SecureFileIO
import Testing

@testable import AwesoMuxCore

@Suite
struct AgentTranscriptImporterTests {
    private static let sessionA = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    private static let sessionB = "9a8b7c6d-5e4f-4321-9876-543210fedcba"

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

        func open(
            sessionID: String?
        ) -> Result<AgentTranscript, AgentTranscriptUnavailable> {
            AgentTranscriptImporter.open(
                agentKind: provider == .claudeCode ? .claudeCode : .codex,
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
