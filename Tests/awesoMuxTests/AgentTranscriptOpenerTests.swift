import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxTestSupport
import Foundation
import SecureFileIO
import Testing

@testable import AwesoMuxCore
@testable import awesoMux

@Suite("Agent transcript opener", .serialized)
struct AgentTranscriptOpenerTests {
    private static let sessionID = "9F1B2C3D-4E5F-4A6B-8C9D-0E1F2A3B4C5D"

    // MARK: - Fixtures

    /// A Claude config home holding one real transcript, plus an isolated
    /// transcript cache.
    private func withFixture(
        lines: [String] = [
            #"{"type":"user","cwd":"/tmp/repo","message":{"content":"opening turn"}}"#,
            #"{"type":"assistant","cwd":"/tmp/repo","message":{"content":"closing turn"}}"#,
        ],
        sessionID: String = AgentTranscriptOpenerTests.sessionID,
        _ operation: (URL, AgentTranscriptStore) throws -> Void
    ) throws {
        let root = try TemporaryDirectory(prefix: "awesomux-transcript-opener")
        defer { withExtendedLifetime(root) {} }
        let configHome = root.url.appending(path: "claude", directoryHint: .isDirectory)
        let projects = configHome.appending(path: "projects/-tmp-repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try Data(lines.joined(separator: "\n").utf8)
            .write(to: projects.appending(path: "\(sessionID).jsonl"))
        let store = AgentTranscriptStore(
            cacheDirectoryURL: root.url.appending(path: "cache", directoryHint: .isDirectory)
        )
        try operation(configHome, store)
    }

    // MARK: - End to end

    @Test("a resolved transcript is rendered, stored, and returned with its provenance")
    func opensRendersAndStores() throws {
        try withFixture { configHome, store in
            let result = AgentTranscriptOpener.open(
                agentKind: .claudeCode,
                executionPlan: .local,
                configHome: configHome,
                reportedSessionID: Self.sessionID,
                workingDirectory: nil,
                store: store
            )
            let opened = try #require(try? result.get())

            #expect(opened.identity.agentKind == .claudeCode)
            #expect(opened.identity.sessionID == Self.sessionID)
            #expect(opened.fileURL.lastPathComponent.hasSuffix(AgentTranscriptStore.fileNameSuffix))

            let markdown = try String(contentsOf: opened.fileURL, encoding: .utf8)
            #expect(markdown.contains("opening turn"))
            #expect(markdown.contains("closing turn"))
        }
    }

    /// The queued localization ASK, resolved: the renderer's chrome is no longer
    /// its own English literals — it is whatever the app layer hands down. This
    /// asserts the app's strings are what reach the document.
    ///
    /// It deliberately does not carry the whole weight of "production never
    /// reaches for `Chrome.unlocalizedFallback`", and could not: the fallback's
    /// English is character-identical to the app's English, so a switched
    /// production call site would pass this test unchanged (review finding).
    /// The fallback is `internal` to `AwesoMuxCore` instead, so that switch is a
    /// compile error in the app target — this test only sees it at all because
    /// the test target imports Core `@testable`.
    @Test("document chrome comes from the app layer's localized strings")
    func documentChromeComesFromTheAppLayer() throws {
        try withFixture { configHome, store in
            let opened = try #require(
                try? AgentTranscriptOpener.open(
                    agentKind: .claudeCode,
                    executionPlan: .local,
                    configHome: configHome,
                    reportedSessionID: Self.sessionID,
                    workingDirectory: nil,
                    store: store
                ).get()
            )
            let markdown = try String(contentsOf: opened.fileURL, encoding: .utf8)
            let chrome = AgentTranscriptOpener.localizedChrome(agentKind: .claudeCode)

            #expect(markdown.hasPrefix("# \(chrome.title)\n"))
            #expect(markdown.contains("\(chrome.sessionLabel) `\(Self.sessionID)`"))
        }
    }

    /// A directory match is a guess: the fallback fires when no id has been
    /// reported, and a directory can hold several sessions. The document has to
    /// say which of the two it is, and the app layer has to be able to see it
    /// too — Resume stages a command against this id.
    @Test("a working-directory match says so in the document and in its result")
    func fallbackResolutionIsVisible() throws {
        try withFixture { configHome, store in
            let byDirectory = try #require(
                try? AgentTranscriptOpener.open(
                    agentKind: .claudeCode,
                    executionPlan: .local,
                    configHome: configHome,
                    reportedSessionID: nil,
                    workingDirectory: "/tmp/repo",
                    store: store
                ).get()
            )
            #expect(byDirectory.resolution == .workingDirectoryFallback)
            let notice = try #require(
                AgentTranscriptOpener.localizedChrome(
                    agentKind: .claudeCode,
                    resolution: .workingDirectoryFallback
                ).provenanceNotice
            )
            let guessed = try String(contentsOf: byDirectory.fileURL, encoding: .utf8)
            #expect(guessed.contains(notice))

            let byID = try #require(
                try? AgentTranscriptOpener.open(
                    agentKind: .claudeCode,
                    executionPlan: .local,
                    configHome: configHome,
                    reportedSessionID: Self.sessionID,
                    workingDirectory: "/tmp/repo",
                    store: store
                ).get()
            )
            #expect(byID.resolution == .reportedSessionID)
            let certain = try String(contentsOf: byID.fileURL, encoding: .utf8)
            #expect(!certain.contains(notice))
            #expect(
                AgentTranscriptOpener.localizedChrome(agentKind: .claudeCode).provenanceNotice
                    == nil
            )
        }
    }

    @Test("chrome is composed per provider")
    func chromeNamesTheProvider() {
        #expect(
            AgentTranscriptOpener.localizedChrome(agentKind: .claudeCode).title
                != AgentTranscriptOpener.localizedChrome(agentKind: .codex).title
        )
        #expect(
            AgentTranscriptOpener.localizedChrome(agentKind: .codex).title.contains("Codex")
        )
    }

    // MARK: - Degrading with a reason

    /// The command must stay live and explain rather than grey out, so every
    /// failure route has to produce a reason the user can act on.
    @Test("a pane with no session identity degrades with its own reason, not a dead command")
    func noSessionIdentityDegradesWithAReason() throws {
        try withFixture { configHome, store in
            let result = AgentTranscriptOpener.open(
                agentKind: .claudeCode,
                executionPlan: .local,
                configHome: configHome,
                reportedSessionID: nil,
                workingDirectory: nil,
                store: store
            )
            guard case .failure(let failure) = result else {
                Issue.record("expected a failure with no id and no working directory")
                return
            }
            #expect(failure == .unavailable(.noSessionIdentity))
            #expect(!AgentTranscriptOpener.unavailableDescription(for: failure).isEmpty)
        }
    }

    @Test("an unmatched session id reports not-found rather than a different session")
    func unmatchedSessionIDReportsNotFound() throws {
        try withFixture { configHome, store in
            let result = AgentTranscriptOpener.open(
                agentKind: .claudeCode,
                executionPlan: .local,
                configHome: configHome,
                reportedSessionID: "11111111-2222-4333-8444-555555555555",
                workingDirectory: "/tmp/repo",
                store: store
            )
            #expect(result == .failure(.unavailable(.notFound)))
        }
    }

    @Test("a remote pane is refused before any local lookup")
    func remotePaneIsRefused() throws {
        let target = try #require(RemoteTarget(user: "alice", host: "remote.example"))
        try withFixture { configHome, store in
            let result = AgentTranscriptOpener.open(
                agentKind: .claudeCode,
                executionPlan: .ssh(SSHExecution(target: target)),
                configHome: configHome,
                reportedSessionID: Self.sessionID,
                workingDirectory: "/tmp/repo",
                store: store
            )
            #expect(result == .failure(.unavailable(.remoteExecution)))
        }
    }

    @Test("an unsupported agent is refused by kind")
    func unsupportedAgentIsRefused() throws {
        try withFixture { configHome, store in
            let result = AgentTranscriptOpener.open(
                agentKind: .grok,
                executionPlan: .local,
                configHome: configHome,
                reportedSessionID: Self.sessionID,
                workingDirectory: nil,
                store: store
            )
            #expect(result == .failure(.unavailable(.unsupportedAgent(.grok))))
        }
    }

    // MARK: - Resume liveness probe

    /// Resume's liveness question is "is the LOG still there", not "is the
    /// process still running" — both CLIs resume a finished session fine.
    @Test("resume's probe sees a finished session's log, and stops seeing a deleted one")
    func sessionLogProbeTracksTheLogNotTheProcess() throws {
        try withFixture { configHome, _ in
            let identity = try #require(
                AgentTranscriptIdentity(agentKind: .claudeCode, sessionID: Self.sessionID)
            )
            #expect(
                AgentTranscriptOpener.sessionLogExists(
                    identity: identity,
                    executionPlan: .local,
                    configHome: configHome
                )
            )

            try FileManager.default.removeItem(
                at: configHome.appending(path: "projects/-tmp-repo/\(Self.sessionID).jsonl")
            )
            #expect(
                !AgentTranscriptOpener.sessionLogExists(
                    identity: identity,
                    executionPlan: .local,
                    configHome: configHome
                ),
                "a deleted log must deny Resume rather than stage a command that will fail"
            )
        }
    }

    /// A sibling session's log in the same directory must not stand in for the
    /// one the document names — no working-directory fallback in this probe.
    @Test("resume's probe never falls back to another session in the same directory")
    func sessionLogProbeDoesNotFallBackToASibling() throws {
        try withFixture { configHome, _ in
            let other = try #require(
                AgentTranscriptIdentity(
                    agentKind: .claudeCode,
                    sessionID: "11111111-2222-4333-8444-555555555555"
                )
            )
            #expect(
                !AgentTranscriptOpener.sessionLogExists(
                    identity: other,
                    executionPlan: .local,
                    configHome: configHome
                )
            )
        }
    }

    // MARK: - The `.shell` provider sweep

    /// Both CLIs in one repository is the maintainer's default, so "Claude ran
    /// here once" must not beat "Codex ran here thirty seconds ago" on
    /// `AgentKind` declaration order. First-hit-wins headed the document
    /// "Claude Code transcript" and staged `claude --resume` into a terminal
    /// that had been running Codex (review finding).
    @Test("the shell sweep resolves the most recently modified provider, not the first")
    func shellSweepPrefersTheMostRecentlyModifiedProvider() throws {
        let root = try TemporaryDirectory(prefix: "awesomux-transcript-sweep")
        defer { withExtendedLifetime(root) {} }
        let store = AgentTranscriptStore(
            cacheDirectoryURL: root.url.appending(path: "cache", directoryHint: .isDirectory)
        )

        let claudeHome = root.url.appending(path: ".claude", directoryHint: .isDirectory)
        let claudeFile =
            claudeHome
            .appending(path: "projects/-tmp-repo", directoryHint: .isDirectory)
            .appending(path: "\(Self.sessionID).jsonl")
        let codexSession = "7C2E4A11-9B33-4D55-8E77-0A1B2C3D4E5F"
        let codexHome = root.url.appending(path: ".codex", directoryHint: .isDirectory)
        let codexFile =
            codexHome
            .appending(path: "sessions/2026/08/16", directoryHint: .isDirectory)
            .appending(path: "rollout-2026-08-16T09-00-00-\(codexSession).jsonl")

        for (url, lines) in [
            (
                claudeFile,
                [
                    #"{"type":"user","cwd":"/tmp/repo","message":{"content":"the older claude turn"}}"#
                ]
            ),
            (
                codexFile,
                [
                    #"{"type":"session_meta","payload":{"cwd":"/tmp/repo","id":"\#(codexSession)"}}"#,
                    #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"the newer codex turn"}]}}"#,
                ]
            ),
        ] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(lines.joined(separator: "\n").utf8).write(to: url)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: claudeFile.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: codexFile.path)

        // Declaration order: Claude is attempt one and resolves, so first-hit
        // wins would stop right here.
        let attempts: [(kind: AgentKind, configHome: URL)] = [
            (kind: .claudeCode, configHome: claudeHome),
            (kind: .codex, configHome: codexHome),
        ]
        let opened = try #require(
            try? AgentTranscriptOpener.open(
                attempts: attempts,
                executionPlan: .local,
                reportedSessionID: nil,
                workingDirectory: "/tmp/repo",
                store: store
            ).get()
        )

        #expect(opened.identity.agentKind == .codex)
        #expect(opened.identity.sessionID == codexSession)
        let markdown = try String(contentsOf: opened.fileURL, encoding: .utf8)
        #expect(markdown.contains("the newer codex turn"))
        #expect(!markdown.contains("the older claude turn"))
        // A cross-provider guess has to say which agent it landed on.
        #expect(markdown.contains(AgentKind.codex.displayName))
    }

    /// The composition itself is the new risk: `.shell` sweeps two providers,
    /// so a hostile reported id gets two chances to reach a filesystem path.
    /// `.notFound` here would mean an attempt fell through to the fallback and
    /// resolved SOMETHING while carrying an id shaped like a shell command.
    @Test("a shell-injection session id is refused by every attempt in the sweep")
    func injectionSessionIDIsRefusedByEveryAttempt() throws {
        let root = try TemporaryDirectory(prefix: "awesomux-transcript-injection")
        defer { withExtendedLifetime(root) {} }
        let store = AgentTranscriptStore(
            cacheDirectoryURL: root.url.appending(path: "cache", directoryHint: .isDirectory)
        )
        let projects = root.url
            .appending(path: ".claude/projects/-tmp-repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try Data(#"{"type":"user","cwd":"/tmp/repo","message":{"content":"a real turn"}}"#.utf8)
            .write(to: projects.appending(path: "\(Self.sessionID).jsonl"))

        let attempts = AgentTranscriptPaneInputs.resolutionAttempts(
            for: .shell,
            integrations: AgentIntegrationsConfig(),
            homeDirectoryURL: root.url
        )
        #expect(attempts.count == 2, "the sweep is what makes this composition new")

        for attempt in attempts {
            let result = AgentTranscriptOpener.open(
                agentKind: attempt.kind,
                executionPlan: .local,
                configHome: attempt.configHome,
                reportedSessionID: "x\nrm -rf ~",
                workingDirectory: "/tmp/repo",
                store: store
            )
            #expect(
                result == .failure(.unavailable(.invalidSessionID)),
                "\(attempt.kind) must refuse the id outright, never fall through to the fallback"
            )
        }

        #expect(
            AgentTranscriptOpener.open(
                attempts: attempts,
                executionPlan: .local,
                reportedSessionID: "x\nrm -rf ~",
                workingDirectory: "/tmp/repo",
                store: store
            ) == .failure(.unavailable(.invalidSessionID))
        )
    }

    /// "No transcript available" for all of them is a support ticket. Each
    /// outcome names a different thing the user can do about it.
    @Test("every failure outcome has its own non-empty description")
    func everyFailureHasDistinctCopy() {
        let failures: [AgentTranscriptOpenFailure] = [
            .cacheWriteFailed,
            .unavailable(.unsupportedAgent(.grok)),
            .unavailable(.remoteExecution),
            .unavailable(.invalidSessionID),
            .unavailable(.noSessionIdentity),
            .unavailable(.notFound),
            .unavailable(.unreadable(.notRegularFile)),
        ]
        let descriptions = failures.map(AgentTranscriptOpener.unavailableDescription(for:))
        #expect(descriptions.allSatisfy { !$0.isEmpty })
        #expect(Set(descriptions).count == failures.count, "each reason needs its own sentence")
    }
}

// MARK: - Resume denial copy

@Suite("Agent transcript resume copy")
struct AgentTranscriptResumeCopyTests {
    @MainActor
    @Test("every resume denial has its own non-empty description")
    func everyResumeDenialHasDistinctCopy() {
        let reasons: [AgentTranscriptResumeUnavailableReason] = [
            .terminalUnavailable,
            .requiresLocalTerminal,
            .foregroundUnverified,
            .agentRunning(.claudeCode),
            .foregroundBusy,
            .transcriptMissing,
            .noResumeSyntax(.grok),
        ]
        let descriptions = reasons.map(DocumentPaneSendBar.resumeUnavailableDescription(for:))
        #expect(descriptions.allSatisfy { !$0.isEmpty })
        #expect(Set(descriptions).count == reasons.count)
    }

    /// The denial has to name the exit, not just refuse: staging a shell command
    /// at a live agent's prompt pastes it as chat.
    @MainActor
    @Test("a live agent denial names the agent to exit")
    func liveAgentDenialNamesTheAgent() {
        let copy = DocumentPaneSendBar.resumeUnavailableDescription(for: .agentRunning(.codex))
        #expect(copy.contains(AgentKind.codex.displayName))
    }

    @MainActor
    @Test("an eligible verdict has no description")
    func eligibleVerdictHasNoDescription() {
        #expect(
            DocumentPaneSendBar.resumeUnavailableDescription(
                for: .eligible(TerminalPane.ID())
            ) == nil
        )
    }
}
