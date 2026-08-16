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
    private static let sessionID = "9f1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d"

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
                    store: store
                ).get()
            )
            let markdown = try String(contentsOf: opened.fileURL, encoding: .utf8)
            let chrome = AgentTranscriptOpener.localizedChrome(agentKind: .claudeCode)

            #expect(markdown.hasPrefix("# \(chrome.title)\n"))
            #expect(markdown.contains("\(chrome.sessionLabel) `\(Self.sessionID)`"))
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
                store: store
            )
            guard case .failure(let failure) = result else {
                Issue.record("expected a failure with no provider session id")
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
            .unavailable(.searchLimitReached),
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
