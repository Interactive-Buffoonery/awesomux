import AwesoMuxBridgeProtocol
import Foundation
import Testing

@testable import AwesoMuxCore

private let sessionA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private let sessionB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

private func identity(_ sessionID: String, _ kind: AgentKind = .claudeCode) -> AgentTranscriptIdentity {
    // Force-unwrapped on purpose: a fixture that stopped validating is a bug in
    // the fixture, and every test below depends on it being a real identity.
    AgentTranscriptIdentity(agentKind: kind, sessionID: sessionID)!
}

@Suite struct AgentTranscriptIdentityTests {
    @Test func acceptsOnlyProvidersWithAKnownTranscriptLayout() {
        #expect(AgentTranscriptIdentity(agentKind: .claudeCode, sessionID: sessionA) != nil)
        #expect(AgentTranscriptIdentity(agentKind: .codex, sessionID: sessionA) != nil)
        #expect(AgentTranscriptIdentity(agentKind: .pi, sessionID: "pi-session-1") != nil)
        #expect(AgentTranscriptIdentity(agentKind: .openCode, sessionID: "ses_01JABC") != nil)
        for kind in [AgentKind.grok, .hermes, .generic, .shell] {
            #expect(AgentTranscriptIdentity(agentKind: kind, sessionID: sessionA) == nil)
        }
    }

    @Test func rejectsSessionIDsThatAreNotUUIDs() {
        for raw in [
            "",
            "   ",
            "not-a-uuid",
            // The two shapes the trust-boundary work exists to stop: a staged
            // command line, and a path traversal into the transcript glob.
            "\(sessionA)\nrm -rf ~",
            "../../../tmp/evil",
            "\(sessionA)x",
        ] {
            #expect(
                AgentTranscriptIdentity(agentKind: .claudeCode, sessionID: raw) == nil,
                "\(raw.debugDescription) must not become provenance"
            )
        }
    }

    @Test func decodeRevalidatesPersistedValues() {
        for json in [
            #"{"agentKind":"Claude Code","sessionID":"not-a-uuid"}"#,
            #"{"agentKind":"OpenCode","sessionID":"not-an-opencode-id"}"#,
            #"{"agentKind":"Grok","sessionID":"\#(sessionA)"}"#,
            #"{"agentKind":"Generic","sessionID":"\#(sessionA)"}"#,
            #"{"agentKind":"Shell","sessionID":"\#(sessionA)"}"#,
        ] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(AgentTranscriptIdentity.self, from: Data(json.utf8))
            }
        }
    }
}

@Suite struct DocumentPaneTranscriptProvenanceTests {
    private func transcriptTab(
        _ sessionID: String = sessionA,
        path: String = "/tmp/cache/abc.transcript.md",
        associatedWith paneID: TerminalPane.ID? = nil
    ) -> DocumentPane {
        DocumentPane(
            fileURL: URL(fileURLWithPath: path),
            title: "Claude Code Transcript",
            associatedTerminalPaneID: paneID,
            agentTranscriptIdentity: identity(sessionID)
        )
    }

    @Test func malformedTranscriptProvenanceDropsTheFieldNotTheTab() throws {
        for value in [
            #"{"agentKind":"Claude Code","sessionID":"not-a-uuid"}"#,
            #"{"agentKind":"A Future Agent","sessionID":"\#(sessionA)"}"#,
            #""a bare string""#,
            "17",
        ] {
            let data = Data(
                """
                {"id":"11111111-1111-1111-1111-111111111111",\
                "fileURL":"file:///tmp/notes.md","title":"notes.md",\
                "agentTranscriptIdentity":\(value)}
                """.utf8
            )
            let pane = try JSONDecoder().decode(DocumentPane.self, from: data)
            #expect(pane.agentTranscriptIdentity == nil)
            #expect(pane.title == "notes.md", "the tab itself must survive")
        }
    }

    /// Routing transcript read-only-ness through `isReadOnlySnapshot` disables
    /// the send bar on the pane the feature adds a Resume control to.
    @Test func documentNudgeTargetStillResolvesForATranscriptTab() {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        let tab = transcriptTab(associatedWith: terminal.id)
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical,
                first: .pane(terminal),
                second: .documentGroup(DocumentGroup(tabs: [tab], selectedTabID: tab.id))
            ))

        #expect(layout.documentNudgeTarget(for: tab.id) == .available(terminal))
    }
}

@Suite struct AgentTranscriptProvenanceThreadingTests {
    private func session() -> (TerminalSession, TerminalPane) {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        var session = TerminalSession(title: "s", workingDirectory: "/tmp", layout: .pane(terminal))
        session.activePaneID = terminal.id
        return (session, terminal)
    }

    private func openTranscript(
        _ sessionID: String,
        path: String,
        associatedWith paneID: TerminalPane.ID,
        in session: TerminalSession
    ) -> (session: TerminalSession, newTabID: DocumentPane.ID)? {
        PaneLayoutReducer.openDocumentTab(
            fileURL: URL(fileURLWithPath: path),
            associatedTerminalPaneID: paneID,
            agentTranscriptIdentity: identity(sessionID),
            in: session,
            now: Date()
        )
    }

    /// A pane outlives the session whose transcript is open beside it. Open
    /// session A's transcript, then session B's from the same terminal: tab A
    /// must still answer A. Anything that asked the pane would answer B.
    @Test func aTranscriptTabKeepsItsOwnSessionAfterThePaneMovesOn() throws {
        let (session, terminal) = session()
        let (afterA, tabA) = try #require(
            openTranscript(sessionA, path: "/tmp/cache/a.transcript.md", associatedWith: terminal.id, in: session)
        )
        let (afterB, tabB) = try #require(
            openTranscript(sessionB, path: "/tmp/cache/b.transcript.md", associatedWith: terminal.id, in: afterA)
        )

        let group = try #require(afterB.layout.firstDocumentGroup)
        #expect(group.tabs.count == 2)
        #expect(tabA != tabB)
        #expect(group.tab(id: tabA)?.agentTranscriptIdentity == identity(sessionA))
        #expect(group.tab(id: tabB)?.agentTranscriptIdentity == identity(sessionB))
    }

    @Test func reopeningATranscriptSlotNeverRetargetsItsProvenance() throws {
        let (session, terminal) = session()
        let path = "/tmp/cache/a.transcript.md"
        let (afterA, tabA) = try #require(
            openTranscript(sessionA, path: path, associatedWith: terminal.id, in: session)
        )
        // Only reachable if a slot were ever reused for another session; the
        // store hashes the identity into the path so it is not, and the tab must
        // keep A rather than silently becoming B if that ever changes.
        let (afterB, tabB) = try #require(
            openTranscript(sessionB, path: path, associatedWith: terminal.id, in: afterA)
        )

        #expect(tabB == tabA, "same path must dedup onto the same tab")
        #expect(
            afterB.layout.firstDocumentGroup?.tab(id: tabA)?.agentTranscriptIdentity
                == identity(sessionA)
        )
    }

    @Test func aTranscriptTabCannotBeNavigatedToAnotherFile() throws {
        let (session, terminal) = session()
        let (afterA, tabA) = try #require(
            openTranscript(sessionA, path: "/tmp/cache/a.transcript.md", associatedWith: terminal.id, in: session)
        )

        #expect(
            PaneLayoutReducer.replaceDocumentTab(
                tabID: tabA,
                fileURL: URL(fileURLWithPath: "/tmp/other.md"),
                in: afterA
            ) == nil,
            "navigating in place would leave the stored identity describing a different document"
        )
    }
}
