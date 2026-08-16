import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxTestSupport
import Foundation
import Testing

@testable import AwesoMuxCore
@testable import awesoMux

@Suite("Agent transcript pane inputs")
struct AgentTranscriptPaneInputsTests {
    private static let home = URL(fileURLWithPath: "/Users/tester")

    private func attempts(
        for kind: AgentKind,
        integrations: AgentIntegrationsConfig = AgentIntegrationsConfig()
    ) -> [(kind: AgentKind, configHome: URL)] {
        AgentTranscriptPaneInputs.resolutionAttempts(
            for: kind,
            integrations: integrations,
            homeDirectoryURL: Self.home
        )
    }

    // MARK: - Post-exit resolution (the pane is `.shell` by the time you ask)

    /// The sequence nobody else caught: run Claude Code, press Ctrl-D, then ask
    /// for the transcript. `sessionEnd` has already reset the pane to `.shell`,
    /// so a lookup keyed on the pane's current kind fails with copy about the
    /// shell — at exactly the moment the scrollback is gone and the transcript
    /// is the only record left.
    @Test("a shell pane sweeps every provider that keeps a readable log")
    func aShellPaneSweepsEveryProviderWithAConfigHome() {
        let swept = attempts(for: .shell)

        #expect(swept.map(\.kind) == [.claudeCode, .codex])
        #expect(swept.map(\.configHome.lastPathComponent) == [".claude", ".codex"])
    }

    @Test("a pane still naming its provider resolves only that provider")
    func aSupportedPaneResolvesOnlyItsOwnProvider() {
        #expect(attempts(for: .claudeCode).map(\.kind) == [.claudeCode])
        #expect(attempts(for: .codex).map(\.kind) == [.codex])
    }

    /// A provider that genuinely writes no readable log keeps its own
    /// `.unsupportedAgent` message — the two meanings `.unsupportedAgent(.shell)`
    /// used to carry are now separated by which of these returns empty.
    @Test("a provider with no readable log is never swept")
    func anUnsupportedProviderIsNotSwept() {
        for kind: AgentKind in [.openCode, .pi, .grok] {
            #expect(attempts(for: kind).isEmpty, "\(kind) has no session log to sweep")
        }
    }

    /// C2: an operator who moves `config_home` installs the hook there, so the
    /// transcript is there too. The sweep must not fall back to `~`.
    @Test("a relocated config home is honoured by the sweep")
    func configHomeOverrideIsHonouredInTheSweep() {
        let integrations = AgentIntegrationsConfig(
            claudeCode: AgentIntegrationSetup(enabled: true, configHome: "/opt/claude-home")
        )
        let swept = attempts(for: .shell, integrations: integrations)

        #expect(swept.first?.configHome.path == "/opt/claude-home")
        #expect(swept.last?.configHome.path == "/Users/tester/.codex")
    }

    /// End to end: a real Claude transcript recorded for the pane's working
    /// directory resolves through the sweep even though the pane now reports
    /// `.shell`.
    @Test("an exited Claude session still resolves from a shell pane")
    func anExitedClaudeSessionStillResolvesFromAShellPane() throws {
        let root = try TemporaryDirectory(prefix: "awesomux-transcript-shell-sweep")
        defer { withExtendedLifetime(root) {} }
        let configHome = root.url.appending(path: ".claude", directoryHint: .isDirectory)
        let projects = configHome.appending(path: "projects/-tmp-repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let sessionID = "11112222-3333-4444-8555-666677778888"
        try Data(
            [
                #"{"type":"user","cwd":"/tmp/repo","message":{"content":"before the exit"}}"#,
                #"{"type":"assistant","cwd":"/tmp/repo","message":{"content":"after the exit"}}"#,
            ].joined(separator: "\n").utf8
        ).write(to: projects.appending(path: "\(sessionID).jsonl"))

        let swept = AgentTranscriptPaneInputs.resolutionAttempts(
            for: .shell,
            integrations: AgentIntegrationsConfig(),
            homeDirectoryURL: root.url
        )
        let claude = try #require(swept.first { $0.kind == .claudeCode })

        // No reported id: `sessionEnd` cleared the latch along with the kind.
        let opened = AgentTranscriptImporter.open(
            agentKind: claude.kind,
            executionPlan: .local,
            configHome: claude.configHome,
            reportedSessionID: nil,
            workingDirectory: "/tmp/repo"
        )

        #expect((try? opened.get())?.sessionID == sessionID)
    }

    // MARK: - Excluded session ids

    /// The fallback's one signal for telling this pane's session from a
    /// neighbour's. Implemented in the importer but inert until it is populated
    /// here, which is the whole finding.
    @Test("ids latched to other panes are collected, and the opening pane's is not")
    @MainActor
    func latchedIDsFromOtherPanesAreCollectedExceptTheOpeningPane() throws {
        let mine = TerminalPane(title: "mine", workingDirectory: "/tmp/repo", executionPlan: .local)
        let neighbour = TerminalPane(
            title: "neighbour", workingDirectory: "/tmp/repo", executionPlan: .local)
        let elsewhere = TerminalPane(
            title: "elsewhere", workingDirectory: "/tmp/other", executionPlan: .local)
        let here = TerminalSession(
            title: "here",
            workingDirectory: "/tmp/repo",
            layout: .split(
                TerminalSplit(orientation: .vertical, first: .pane(mine), second: .pane(neighbour))),
            activePaneID: mine.id
        )
        let there = TerminalSession(
            title: "there",
            workingDirectory: "/tmp/other",
            layout: .pane(elsewhere),
            activePaneID: elsewhere.id
        )
        let store = SessionStore(groups: [SessionGroup(name: "g", sessions: [here, there])])

        let mineID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        let neighbourID = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
        let elsewhereID = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
        func latch(_ id: String, session: TerminalSession.ID, pane: TerminalPane.ID, event: String) {
            store.applyAgentRuntimeEvent(
                AgentRuntimeEvent(
                    source: .claudeCode,
                    kind: .claudeCode,
                    phase: .sessionStart,
                    eventID: event,
                    providerSessionID: id
                ),
                to: session,
                paneID: pane
            )
        }
        latch(mineID, session: here.id, pane: mine.id, event: "a")
        latch(neighbourID, session: here.id, pane: neighbour.id, event: "b")
        latch(elsewhereID, session: there.id, pane: elsewhere.id, event: "c")

        // Guard the fixture: a latch that silently failed would make the
        // assertion below pass for the wrong reason.
        #expect(store.agentProviderSessionID(for: mine.id) == mineID)

        let excluded = AgentTranscriptPaneInputs.sessionIDsLatchedToOtherPanes(
            excluding: mine.id,
            in: store
        )

        #expect(excluded == [neighbourID, elsewhereID])
        #expect(!excluded.contains(mineID), "the pane being opened must never exclude its own session")
    }
}
