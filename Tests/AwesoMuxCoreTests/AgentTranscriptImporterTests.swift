import AwesoMuxBridgeProtocol
import AwesoMuxTestSupport
import Foundation
import SecureFileIO
import Testing

@testable import AwesoMuxCore

@Suite struct AgentTranscriptImporterTests {

    // MARK: - Fixtures

    /// A provider config home with a Claude `projects/` and a Codex `sessions/`
    /// tree, so both layouts can be built without touching the real home.
    private struct Fixture {
        let directory: TemporaryDirectory
        var configHome: URL { directory.url }

        init() throws {
            directory = try TemporaryDirectory(prefix: "agent-transcript")
        }

        @discardableResult
        func writeClaudeTranscript(
            slug: String,
            sessionID: String,
            lines: [String],
            modified: Date? = nil
        ) throws -> URL {
            let url =
                configHome
                .appending(path: "projects", directoryHint: .isDirectory)
                .appending(path: slug, directoryHint: .isDirectory)
                .appending(path: "\(sessionID).jsonl")
            try write(lines, to: url, modified: modified)
            return url
        }

        @discardableResult
        func writeCodexRollout(
            day: String,
            timestamp: String,
            sessionID: String,
            lines: [String],
            modified: Date? = nil
        ) throws -> URL {
            let url =
                configHome
                .appending(path: "sessions", directoryHint: .isDirectory)
                .appending(path: day, directoryHint: .isDirectory)
                .appending(path: "rollout-\(timestamp)-\(sessionID).jsonl")
            try write(lines, to: url, modified: modified)
            return url
        }

        private func write(_ lines: [String], to url: URL, modified: Date?) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
            if let modified {
                try FileManager.default.setAttributes(
                    [.modificationDate: modified],
                    ofItemAtPath: url.path
                )
            }
        }
    }

    private static let sessionA = "000f4ef0-c60c-44df-a9b8-4cc37de71f2d"
    private static let sessionB = "5723c4f0-8806-4f88-86f7-01de1bcb9df9"

    private static func claudeConversation(sessionID: String, cwd: String) -> [String] {
        [
            #"{"type":"last-prompt","leafUuid":"x","sessionId":"\#(sessionID)"}"#,
            #"{"type":"mode","mode":"default","sessionId":"\#(sessionID)"}"#,
            #"{"type":"user","cwd":"\#(cwd)","sessionId":"\#(sessionID)","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"assistant","cwd":"\#(cwd)","sessionId":"\#(sessionID)","message":{"role":"assistant","content":[{"type":"text","text":"hello"}]}}"#,
        ]
    }

    /// The worktree-relocation sidecar measured on a real machine: same session
    /// id, different project directory, metadata records only.
    private static func claudeRelocationStub(sessionID: String) -> [String] {
        [
            #"{"type":"last-prompt","leafUuid":"x","sessionId":"\#(sessionID)"}"#,
            #"{"type":"ai-title","title":"whatever","sessionId":"\#(sessionID)"}"#,
            #"{"type":"mode","mode":"default","sessionId":"\#(sessionID)"}"#,
            #"{"type":"permission-mode","permissionMode":"default","sessionId":"\#(sessionID)"}"#,
            #"{"type":"worktree-state","state":"relocated","sessionId":"\#(sessionID)"}"#,
            #"{"type":"pr-link","url":"https://example.invalid/1","sessionId":"\#(sessionID)"}"#,
        ]
    }

    private static func codexRollout(sessionID: String, cwd: String) -> [String] {
        [
            #"{"timestamp":"2026-08-15T20:30:43.551Z","type":"session_meta","payload":{"session_id":"\#(sessionID)","id":"\#(sessionID)","cwd":"\#(cwd)","cli_version":"0.147.0"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"hello"}}"#,
        ]
    }

    /// A conversationless transcript of an arbitrary size, standing in for the
    /// real shape the head window cannot see past: a session whose opening
    /// `file-history-snapshot` records embed enough file content to bury the
    /// first turn.
    private static func claudeConversationlessBulk(sessionID: String, records: Int) -> [String] {
        let filler = String(repeating: "x", count: 4_096)
        return claudeRelocationStub(sessionID: sessionID)
            + (0..<records).map { _ in #"{"type":"system","note":"\#(filler)"}"# }
    }

    private static func open(
        _ fixture: Fixture,
        agentKind: AgentKind = .claudeCode,
        executionPlan: PaneExecutionPlan = .local,
        sessionID: String? = nil,
        workingDirectory: String? = nil,
        excludedSessionIDs: Set<String> = []
    ) -> Result<AgentTranscript, AgentTranscriptUnavailable> {
        AgentTranscriptImporter.open(
            agentKind: agentKind,
            executionPlan: executionPlan,
            configHome: fixture.configHome,
            reportedSessionID: sessionID,
            workingDirectory: workingDirectory,
            excludedSessionIDs: excludedSessionIDs
        )
    }

    private static func failure(
        _ result: Result<AgentTranscript, AgentTranscriptUnavailable>
    ) -> AgentTranscriptUnavailable? {
        guard case let .failure(reason) = result else { return nil }
        return reason
    }

    // MARK: - Happy paths

    @Test func opensClaudeTranscriptByReportedSessionID() throws {
        let fixture = try Fixture()
        let url = try fixture.writeClaudeTranscript(
            slug: "-Users-someone-project",
            sessionID: Self.sessionA,
            lines: Self.claudeConversation(sessionID: Self.sessionA, cwd: "/Users/someone/project")
        )

        let transcript = try Self.open(fixture, sessionID: Self.sessionA).get()
        #expect(transcript.agentKind == .claudeCode)
        #expect(transcript.sessionID == Self.sessionA)
        #expect(transcript.resolution == .reportedSessionID)
        #expect(transcript.resolvedURL.lastPathComponent == url.lastPathComponent)
        #expect(transcript.handle.size > 0)
    }

    @Test func opensCodexRolloutByReportedSessionID() throws {
        let fixture = try Fixture()
        try fixture.writeCodexRollout(
            day: "2026/08/15",
            timestamp: "2026-08-15T20-30-42",
            sessionID: Self.sessionB,
            lines: Self.codexRollout(sessionID: Self.sessionB, cwd: "/Users/someone/project")
        )

        let transcript = try Self.open(fixture, agentKind: .codex, sessionID: Self.sessionB).get()
        #expect(transcript.agentKind == .codex)
        #expect(transcript.sessionID == Self.sessionB)
        #expect(transcript.resolution == .reportedSessionID)
        #expect(
            transcript.resolvedURL.lastPathComponent
                == "rollout-2026-08-15T20-30-42-\(Self.sessionB).jsonl"
        )
    }

    // MARK: - Duplicate basenames

    @Test func prefersConversationTranscriptOverNewerRelocationStub() throws {
        let fixture = try Fixture()
        try fixture.writeClaudeTranscript(
            slug: "-Users-someone-project",
            sessionID: Self.sessionA,
            lines: Self.claudeConversation(sessionID: Self.sessionA, cwd: "/Users/someone/project"),
            modified: Date(timeIntervalSince1970: 1_000)
        )
        // The stub is BOTH newer and the one a working-directory tie-break would
        // pick when the pane is in the worktree, so it wins on every heuristic
        // except content.
        try fixture.writeClaudeTranscript(
            slug: "-Users-someone-project--worktrees-fix",
            sessionID: Self.sessionA,
            lines: Self.claudeRelocationStub(sessionID: Self.sessionA),
            modified: Date(timeIntervalSince1970: 9_000)
        )

        let transcript = try Self.open(fixture, sessionID: Self.sessionA).get()
        #expect(
            transcript.resolvedURL.deletingLastPathComponent().lastPathComponent
                == "-Users-someone-project"
        )
    }

    @Test func newestModificationBreaksTieAmongConversationTranscripts() throws {
        let fixture = try Fixture()
        try fixture.writeClaudeTranscript(
            slug: "-Users-someone-old",
            sessionID: Self.sessionA,
            lines: Self.claudeConversation(sessionID: Self.sessionA, cwd: "/Users/someone/old"),
            modified: Date(timeIntervalSince1970: 1_000)
        )
        try fixture.writeClaudeTranscript(
            slug: "-Users-someone-new",
            sessionID: Self.sessionA,
            lines: Self.claudeConversation(sessionID: Self.sessionA, cwd: "/Users/someone/new"),
            modified: Date(timeIntervalSince1970: 9_000)
        )

        let transcript = try Self.open(fixture, sessionID: Self.sessionA).get()
        #expect(transcript.resolvedURL.deletingLastPathComponent().lastPathComponent == "-Users-someone-new")
    }

    /// The tie-break's own fallback, and the branch nothing covered before.
    /// Both candidates read as conversationless — in the field the real
    /// transcript does that by burying its first turn behind
    /// `file-history-snapshot` bulk, which the head window cannot see past — so
    /// mtime used to decide, and a relocation stub is rewritten on every
    /// relocation, which makes it the newer file. Size is the signal that does
    /// not lie: 1.4 KB against 14 MB on the real corpus.
    @Test func largestCandidateWinsWhenNoneShowsAConversation() throws {
        let fixture = try Fixture()
        try fixture.writeClaudeTranscript(
            slug: "-Users-someone-project",
            sessionID: Self.sessionA,
            lines: Self.claudeConversationlessBulk(sessionID: Self.sessionA, records: 8),
            modified: Date(timeIntervalSince1970: 1_000)
        )
        try fixture.writeClaudeTranscript(
            slug: "-Users-someone-project--worktrees-fix",
            sessionID: Self.sessionA,
            lines: Self.claudeRelocationStub(sessionID: Self.sessionA),
            modified: Date(timeIntervalSince1970: 9_000)
        )

        let transcript = try Self.open(fixture, sessionID: Self.sessionA).get()
        #expect(
            transcript.resolvedURL.deletingLastPathComponent().lastPathComponent
                == "-Users-someone-project"
        )
    }

    // MARK: - Working-directory fallback

    @Test func fallsBackToNewestTranscriptRecordingTheWorkingDirectory() throws {
        let fixture = try Fixture()
        try fixture.writeClaudeTranscript(
            slug: "-Users-someone-other",
            sessionID: Self.sessionB,
            lines: Self.claudeConversation(sessionID: Self.sessionB, cwd: "/Users/someone/other"),
            modified: Date(timeIntervalSince1970: 9_000)
        )
        try fixture.writeClaudeTranscript(
            slug: "-Users-someone-project",
            sessionID: Self.sessionA,
            lines: Self.claudeConversation(sessionID: Self.sessionA, cwd: "/Users/someone/project"),
            modified: Date(timeIntervalSince1970: 1_000)
        )

        let transcript = try Self.open(fixture, workingDirectory: "/Users/someone/project").get()
        #expect(transcript.sessionID == Self.sessionA)
        #expect(transcript.resolution == .workingDirectoryFallback)
    }

    @Test func codexFallbackReadsSessionMetaWorkingDirectory() throws {
        let fixture = try Fixture()
        try fixture.writeCodexRollout(
            day: "2026/08/14",
            timestamp: "2026-08-14T10-00-00",
            sessionID: Self.sessionA,
            lines: Self.codexRollout(sessionID: Self.sessionA, cwd: "/Users/someone/project")
        )

        let transcript = try Self.open(
            fixture,
            agentKind: .codex,
            workingDirectory: "/Users/someone/project"
        ).get()
        #expect(transcript.sessionID == Self.sessionA)
        #expect(transcript.resolution == .workingDirectoryFallback)
    }

    @Test func fallbackIgnoresTranscriptsForOtherWorkingDirectories() throws {
        let fixture = try Fixture()
        try fixture.writeClaudeTranscript(
            slug: "-Users-someone-other",
            sessionID: Self.sessionB,
            lines: Self.claudeConversation(sessionID: Self.sessionB, cwd: "/Users/someone/other")
        )

        #expect(
            Self.failure(Self.open(fixture, workingDirectory: "/Users/someone/project")) == .notFound
        )
    }

    /// Claude names each project directory after its working directory, so the
    /// pane's own project is searched before anything else. Without that, the
    /// newest file recording the same `cwd` won — and a session relocated into
    /// a worktree keeps recording the directory it started in.
    @Test func claudeFallbackPrefersThePanesOwnProjectDirectory() throws {
        let fixture = try Fixture()
        try fixture.writeClaudeTranscript(
            slug: "-Users-someone-project",
            sessionID: Self.sessionA,
            lines: Self.claudeConversation(sessionID: Self.sessionA, cwd: "/Users/someone/project"),
            modified: Date(timeIntervalSince1970: 1_000)
        )
        try fixture.writeClaudeTranscript(
            slug: "-Users-someone-project--worktrees-fix",
            sessionID: Self.sessionB,
            lines: Self.claudeConversation(sessionID: Self.sessionB, cwd: "/Users/someone/project"),
            modified: Date(timeIntervalSince1970: 9_000)
        )

        let transcript = try Self.open(fixture, workingDirectory: "/Users/someone/project").get()
        #expect(transcript.sessionID == Self.sessionA)
    }

    /// The slug rule is Claude's, not ours, and a relocated session records a
    /// directory whose slug it no longer lives under. A scoped miss has to
    /// widen to the full scan, never turn into `.notFound`.
    @Test func claudeFallbackWidensBeyondTheProjectDirectory() throws {
        let fixture = try Fixture()
        try fixture.writeClaudeTranscript(
            slug: "-Users-someone-project--worktrees-fix",
            sessionID: Self.sessionA,
            lines: Self.claudeConversation(sessionID: Self.sessionA, cwd: "/Users/someone/project")
        )

        let transcript = try Self.open(fixture, workingDirectory: "/Users/someone/project").get()
        #expect(transcript.sessionID == Self.sessionA)
        #expect(transcript.resolution == .workingDirectoryFallback)
    }

    /// The neighbouring-pane bug. Two panes in one directory both match on
    /// `cwd`, and the neighbour's file is newer precisely because its agent is
    /// writing to it — so mtime hands this pane the transcript of a session
    /// that is live next door, and Resume would fork it. A pane whose agent has
    /// reported anything has a latched id, and that id is spoken for.
    @Test func fallbackSkipsSessionsLatchedToAnotherPane() throws {
        let fixture = try Fixture()
        try fixture.writeClaudeTranscript(
            slug: "-Users-someone-project",
            sessionID: Self.sessionA,
            lines: Self.claudeConversation(sessionID: Self.sessionA, cwd: "/Users/someone/project"),
            modified: Date(timeIntervalSince1970: 1_000)
        )
        try fixture.writeClaudeTranscript(
            slug: "-Users-someone-project",
            sessionID: Self.sessionB,
            lines: Self.claudeConversation(sessionID: Self.sessionB, cwd: "/Users/someone/project"),
            modified: Date(timeIntervalSince1970: 9_000)
        )

        #expect(try Self.open(fixture, workingDirectory: "/Users/someone/project").get().sessionID == Self.sessionB)

        let transcript = try Self.open(
            fixture,
            workingDirectory: "/Users/someone/project",
            excludedSessionIDs: [Self.sessionB]
        ).get()
        #expect(transcript.sessionID == Self.sessionA)
    }

    /// Codex records the working directory inside the file, so its tree cannot
    /// be scoped by path and the scan has to reach every rollout. The old
    /// 200-file global cap stopped short of this one.
    @Test func codexFallbackScansPastTheOldGlobalCandidateCap() throws {
        let fixture = try Fixture()
        try fixture.writeCodexRollout(
            day: "2026/01/01",
            timestamp: "2026-01-01T00-00-00",
            sessionID: Self.sessionA,
            lines: Self.codexRollout(sessionID: Self.sessionA, cwd: "/Users/someone/project"),
            modified: Date(timeIntervalSince1970: 1_000)
        )
        for index in 0..<250 {
            try fixture.writeCodexRollout(
                day: "2026/08/15",
                timestamp: "2026-08-15T20-30-42",
                sessionID: UUID().uuidString,
                lines: Self.codexRollout(sessionID: UUID().uuidString, cwd: "/Users/someone/other"),
                modified: Date(timeIntervalSince1970: 9_000 + Double(index))
            )
        }

        let transcript = try Self.open(
            fixture,
            agentKind: .codex,
            workingDirectory: "/Users/someone/project"
        ).get()
        #expect(transcript.sessionID == Self.sessionA)
    }

    // MARK: - Rejections

    @Test(arguments: [AgentKind.grok, .openCode, .pi, .shell])
    func rejectsUnsupportedAgents(kind: AgentKind) throws {
        let fixture = try Fixture()
        try fixture.writeClaudeTranscript(
            slug: "-Users-someone-project",
            sessionID: Self.sessionA,
            lines: Self.claudeConversation(sessionID: Self.sessionA, cwd: "/Users/someone/project")
        )

        #expect(
            Self.failure(Self.open(fixture, agentKind: kind, sessionID: Self.sessionA))
                == .unsupportedAgent(kind)
        )
    }

    @Test(
        arguments: [
            "not-a-uuid",
            "../../../tmp/evil",
            "000f4ef0-c60c-44df-a9b8-4cc37de71f2d/../escape",
            String(repeating: "a", count: 200),
        ])
    func rejectsNonUUIDSessionIDs(raw: String) throws {
        let fixture = try Fixture()
        #expect(Self.failure(Self.open(fixture, sessionID: raw)) == .invalidSessionID)
    }

    @Test func rejectsRemotePanes() throws {
        let fixture = try Fixture()
        try fixture.writeClaudeTranscript(
            slug: "-Users-someone-project",
            sessionID: Self.sessionA,
            lines: Self.claudeConversation(sessionID: Self.sessionA, cwd: "/Users/someone/project")
        )
        let target = try #require(RemoteTarget(parsing: "example.invalid"))

        #expect(
            Self.failure(
                Self.open(
                    fixture,
                    executionPlan: .ssh(SSHExecution(target: target)),
                    sessionID: Self.sessionA
                )
            ) == .remoteExecution
        )
    }

    @Test func reportsNoSessionIdentityWithoutIDOrWorkingDirectory() throws {
        let fixture = try Fixture()
        #expect(Self.failure(Self.open(fixture)) == .noSessionIdentity)
    }

    @Test func reportsNotFoundWhenNoTranscriptMatches() throws {
        let fixture = try Fixture()
        try fixture.writeClaudeTranscript(
            slug: "-Users-someone-project",
            sessionID: Self.sessionB,
            lines: Self.claudeConversation(sessionID: Self.sessionB, cwd: "/Users/someone/project")
        )

        #expect(Self.failure(Self.open(fixture, sessionID: Self.sessionA)) == .notFound)
    }

    @Test func reportsNotFoundWhenProviderRootIsMissingEntirely() throws {
        let fixture = try Fixture()
        #expect(Self.failure(Self.open(fixture, sessionID: Self.sessionA)) == .notFound)
    }

    @Test func rejectsSymlinkedCandidate() throws {
        let fixture = try Fixture()
        let real = try fixture.writeClaudeTranscript(
            slug: "-Users-someone-project",
            sessionID: Self.sessionB,
            lines: Self.claudeConversation(sessionID: Self.sessionB, cwd: "/Users/someone/project")
        )
        let link =
            fixture.configHome
            .appending(path: "projects", directoryHint: .isDirectory)
            .appending(path: "-Users-someone-project", directoryHint: .isDirectory)
            .appending(path: "\(Self.sessionA).jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(
            Self.failure(Self.open(fixture, sessionID: Self.sessionA))
                == .unreadable(.unreadable)
        )
    }

    @Test func rejectsCandidateOwnedByAnotherUser() throws {
        let fixture = try Fixture()
        try fixture.writeClaudeTranscript(
            slug: "-Users-someone-project",
            sessionID: Self.sessionA,
            lines: Self.claudeConversation(sessionID: Self.sessionA, cwd: "/Users/someone/project")
        )

        let result = AgentTranscriptImporter.open(
            agentKind: .claudeCode,
            executionPlan: .local,
            configHome: fixture.configHome,
            reportedSessionID: Self.sessionA,
            workingDirectory: nil,
            effectiveUID: geteuid() &+ 1
        )
        #expect(Self.failure(result) == .unreadable(.wrongOwner))
    }

    // MARK: - Large transcripts

    /// Real transcripts run to tens of megabytes. The head read must window
    /// them, not reject them — `SecureFileReadHandle.read` treats a file longer
    /// than its cap as `.tooLarge`, which would fail every real transcript.
    @Test func resolvesTranscriptsLargerThanTheHeadWindow() throws {
        let fixture = try Fixture()
        let filler = String(repeating: "x", count: 4_096)
        var lines = Self.claudeConversation(sessionID: Self.sessionA, cwd: "/Users/someone/project")
        for _ in 0..<128 {
            lines.append(#"{"type":"system","note":"\#(filler)"}"#)
        }
        let url = try fixture.writeClaudeTranscript(
            slug: "-Users-someone-project",
            sessionID: Self.sessionA,
            lines: lines
        )
        let size = try #require(
            try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        )
        #expect(size > AgentTranscriptImporter.headByteCount)

        // Both paths read the head: the fallback always, and the tie-break once
        // a second candidate exists.
        try fixture.writeClaudeTranscript(
            slug: "-Users-someone-project--worktrees-fix",
            sessionID: Self.sessionA,
            lines: Self.claudeRelocationStub(sessionID: Self.sessionA),
            modified: Date(timeIntervalSince1970: 9_000)
        )

        let byID = try Self.open(fixture, sessionID: Self.sessionA).get()
        #expect(
            byID.resolvedURL.deletingLastPathComponent().lastPathComponent
                == "-Users-someone-project"
        )

        let byCWD = try Self.open(fixture, workingDirectory: "/Users/someone/project").get()
        #expect(byCWD.resolution == .workingDirectoryFallback)
        #expect(byCWD.sessionID == Self.sessionA)
    }

    /// The fallback's probe is sized for reaching a `cwd`, not for the
    /// conversation tie-break, and the two are now separate constants. Measured
    /// across 324 real Claude transcripts the worst case is 11,766 bytes, so a
    /// ~20 KB run of leading metadata has to resolve and a probe shrunk to
    /// 8-16 KiB has to fail here rather than silently skipping the candidate.
    @Test func fallbackProbeReachesCWDBehindLeadingMetadata() throws {
        let fixture = try Fixture()
        let filler = String(repeating: "m", count: 20_000)
        try fixture.writeClaudeTranscript(
            slug: "-Users-someone-project",
            sessionID: Self.sessionA,
            lines: [#"{"type":"last-prompt","lastPrompt":"\#(filler)"}"#]
                + Self.claudeConversation(sessionID: Self.sessionA, cwd: "/Users/someone/project")
        )

        let resolved = try Self.open(fixture, workingDirectory: "/Users/someone/project").get()
        #expect(resolved.sessionID == Self.sessionA)
        #expect(resolved.resolution == .workingDirectoryFallback)
        #expect(
            AgentTranscriptImporter.Provider.claudeCode.workingDirectoryProbeByteCount
                < AgentTranscriptImporter.headByteCount,
            "the probe must not inherit the tie-break's window; that capped the scan at ~256 files"
        )
    }

    // MARK: - Head parsing

    @Test func headParsingSkipsTruncatedTrailingLine() {
        let complete = #"{"type":"user","cwd":"/Users/someone/project"}"#
        let truncated = #"{"type":"assistant","cwd":"/somewhere"#
        let head = AgentTranscriptImporter.parseHead(
            Data("\(complete)\n\(truncated)".utf8),
            provider: .claudeCode
        )
        #expect(head.hasConversationRecord)
        #expect(head.recordedWorkingDirectory == "/Users/someone/project")
    }

    @Test func headParsingFindsNoConversationInRelocationStub() {
        let head = AgentTranscriptImporter.parseHead(
            Data((Self.claudeRelocationStub(sessionID: Self.sessionA).joined(separator: "\n") + "\n").utf8),
            provider: .claudeCode
        )
        #expect(!head.hasConversationRecord)
        #expect(head.recordedWorkingDirectory == nil)
    }
}
