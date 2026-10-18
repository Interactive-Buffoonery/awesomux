import AwesoMuxBridgeProtocol
import AwesoMuxTestSupport
import Foundation
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

    // MARK: - Refreshing a live session

    private static let turnA =
        #"{"type":"user","cwd":"/tmp/repo","message":{"content":"opening turn"}}"#
    private static let turnB =
        #"{"type":"assistant","cwd":"/tmp/repo","message":{"content":"later turn"}}"#

    private func resolvedTranscript(configHome: URL) throws -> AgentTranscript {
        try AgentTranscriptImporter.open(
            agentKind: .claudeCode,
            executionPlan: .local,
            configHome: configHome,
            reportedSessionID: Self.sessionID
        ).get()
    }

    /// `open` passes `skippingUnchanged: false` because the user just asked for
    /// the document: a slot something else pruned has to be put back rather
    /// than assumed present.
    @Test("opening restores a cache slot that was pruned, even with an unchanged source")
    func openRewritesAPrunedCacheSlot() throws {
        try withFixture(lines: [Self.turnA]) { configHome, store in
            func open() -> Result<OpenedAgentTranscript, AgentTranscriptOpenFailure> {
                AgentTranscriptOpener.open(
                    agentKind: .claudeCode,
                    executionPlan: .local,
                    configHome: configHome,
                    reportedSessionID: Self.sessionID,
                    store: store
                )
            }
            let first = try #require(try? open().get())
            try FileManager.default.removeItem(at: first.fileURL)

            let second = try #require(try? open().get())

            #expect(second.fileURL == first.fileURL)
            #expect(
                try String(contentsOf: second.fileURL, encoding: .utf8).contains("opening turn")
            )
        }
    }

    /// The commit gate only orders anything if the production path hands it to
    /// the store. `AgentTranscriptStore.write` defaults `shouldCommit` to
    /// `{ true }`, so a `renderAndStore` that renders the gate and then drops
    /// it leaves the authoritative in-lock check evaluating a constant — while
    /// every store-level test still passes, because those call `write` directly
    /// and supply the closure themselves.
    ///
    /// Answering `true` once and `false` afterwards is what separates the two
    /// questions. The opener's own cheap early-out consumes the `true` and
    /// proceeds to the store, so only a gate that was actually forwarded can
    /// refuse the write from inside the cache lock. A dropped argument shows up
    /// twice over: the gate is asked once instead of twice, and the sentinel
    /// bytes are gone.
    @Test("refresh forwards its commit gate into the cache write's critical section")
    func refreshForwardsTheCommitGateToTheStore() throws {
        try withFixture(lines: [Self.turnA]) { configHome, store in
            let prior = try self.resolvedTranscript(configHome: configHome)
            let slot = try #require(
                store.write("sentinel", agentKind: .claudeCode, sessionID: Self.sessionID)
            )

            var answers = 0
            let refreshed = try #require(
                try? AgentTranscriptOpener.refresh(prior, store: store) {
                    answers += 1
                    return answers == 1
                }.get()
            )

            #expect(refreshed == slot)
            #expect(
                try String(contentsOf: slot, encoding: .utf8) == "sentinel",
                "a refused render committed anyway: the store ran its own default gate"
            )
        }
    }

    // MARK: - Degrading with a reason

    /// The command must stay live and explain rather than grey out, so every
    /// failure route has to produce a reason the user can act on.
    enum IdentityFailuresCase: String, CaseIterable {
        case noSessionIdentityDegradesWithAReason
        case unmatchedSessionIDReportsNotFound
        case remotePaneIsRefused
    }

    @Test(arguments: IdentityFailuresCase.allCases)
    func identityFailures(_ scenario: IdentityFailuresCase) throws {
        switch scenario {
        case .noSessionIdentityDegradesWithAReason:
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
        case .unmatchedSessionIDReportsNotFound:
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
        case .remotePaneIsRefused:
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
    }

    // MARK: - Resume liveness probe

    /// Resume's liveness question is "is the LOG still there", not "is the
    /// process still running" — both CLIs resume a finished session fine.
    enum SessionLogProbeCase: String, CaseIterable {
        case sessionLogProbeTracksTheLogNotTheProcess
        case sessionLogProbeDoesNotFallBackToASibling
    }

    @Test(arguments: SessionLogProbeCase.allCases)
    func sessionLogProbe(_ scenario: SessionLogProbeCase) throws {
        switch scenario {
        case .sessionLogProbeTracksTheLogNotTheProcess:
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
        case .sessionLogProbeDoesNotFallBackToASibling:
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
    }

    /// "No transcript available" for all of them is a support ticket. Each
    /// outcome names a different thing the user can do about it.

}
