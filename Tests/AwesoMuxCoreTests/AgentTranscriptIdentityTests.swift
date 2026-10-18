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
    @Test(arguments: ["", "   ", "not-a-uuid", "\(sessionA)\nrm -rf ~", "../../../tmp/evil", "\(sessionA)x"])
    func rejectsInvalidSessionID(raw: String) {
        #expect(AgentTranscriptIdentity(agentKind: .claudeCode, sessionID: raw) == nil)
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
}
