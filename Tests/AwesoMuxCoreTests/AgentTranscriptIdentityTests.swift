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
        for kind in [AgentKind.openCode, .grok, .shell] {
            #expect(AgentTranscriptIdentity(agentKind: kind, sessionID: sessionA) == nil)
        }
        #expect(AgentTranscriptIdentity(agentKind: .openCode, sessionID: "ses_01JABC") == nil)
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

    @Test func trimsSurroundingWhitespace() throws {
        let identity = try #require(
            AgentTranscriptIdentity(agentKind: .codex, sessionID: "  \(sessionA)\n")
        )
        #expect(identity.sessionID == sessionA)
    }

    @Test func documentTitleNamesTheProvider() {
        #expect(identity(sessionA, .claudeCode).documentTitle == "Claude Code Transcript")
        #expect(identity(sessionA, .codex).documentTitle == "Codex Transcript")
        #expect(identity("pi-session-1", .pi).documentTitle == "Pi Transcript")
    }

    @Test func codableRoundTrip() throws {
        let original = identity(sessionA, .codex)
        let decoded = try JSONDecoder().decode(
            AgentTranscriptIdentity.self,
            from: JSONEncoder().encode(original)
        )
        #expect(decoded == original)
    }

    @Test func decodeRevalidatesPersistedValues() {
        for json in [
            #"{"agentKind":"Claude Code","sessionID":"not-a-uuid"}"#,
            #"{"agentKind":"OpenCode","sessionID":"ses_01JABC"}"#,
            #"{"agentKind":"Grok","sessionID":"\#(sessionA)"}"#,
            #"{"agentKind":"Shell","sessionID":"\#(sessionA)"}"#,
        ] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(AgentTranscriptIdentity.self, from: Data(json.utf8))
            }
        }
    }
}

// MARK: - Provenance on the document

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

    @Test func transcriptProvenanceRoundTripsThroughCodable() throws {
        let pane = transcriptTab()
        let decoded = try JSONDecoder().decode(
            DocumentPane.self,
            from: JSONEncoder().encode(pane)
        )
        #expect(decoded == pane)
        #expect(decoded.agentTranscriptIdentity == identity(sessionA))
        #expect(!decoded.isEditable)
    }

    @Test func plainDocumentRoundTripsWithoutTheField() throws {
        let pane = DocumentPane(fileURL: URL(fileURLWithPath: "/tmp/notes.md"), title: "notes.md")
        let encoded = try JSONEncoder().encode(pane)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(json["agentTranscriptIdentity"] == nil, "nil provenance must not be written")
        let decoded = try JSONDecoder().decode(DocumentPane.self, from: encoded)
        #expect(decoded == pane)
        #expect(decoded.isEditable)
    }

    @Test func snapshotPredatingTheFieldDecodesAsAPlainDocument() throws {
        let data = Data(
            #"{"id":"11111111-1111-1111-1111-111111111111","fileURL":"file:///tmp/notes.md","title":"notes.md"}"#
                .utf8
        )
        let pane = try JSONDecoder().decode(DocumentPane.self, from: data)

        #expect(pane.agentTranscriptIdentity == nil)
        #expect(pane.isEditable)
        #expect(!pane.isReadOnlySnapshot)
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

    // MARK: The three properties that must NOT change

    @Test func transcriptTabIsNotAReadOnlyRemoteSnapshot() {
        let pane = transcriptTab()
        #expect(!pane.isReadOnlySnapshot, "isReadOnlySnapshot means remote provenance, only")
        #expect(pane.remoteSnapshotOrigin == nil)
        #expect(!pane.isEditable)
    }

    @Test func transcriptTabDoesNotStripLocalFileAccessFromItsSiblings() {
        let localTab = DocumentPane(fileURL: URL(fileURLWithPath: "/tmp/notes.md"), title: "notes.md")
        let group = DocumentGroup(
            tabs: [localTab, transcriptTab()],
            selectedTabID: localTab.id
        )

        let capabilities = WorkspaceLeaf.documentGroup(group).capabilities

        #expect(capabilities.localFileAccess, "a local Markdown tab keeps local-file standing")
        #expect(!capabilities.remoteProvenance, "a locally rendered transcript is not remote")
    }

    /// The regression this whole task exists to prevent: routing transcript
    /// read-only-ness through `isReadOnlySnapshot` disables the send bar on the
    /// very pane the feature adds a Resume control to.
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

    @Test func transcriptTabIsNotEditableWhileANormalLocalTabIs() {
        let localTab = DocumentPane(fileURL: URL(fileURLWithPath: "/tmp/notes.md"), title: "notes.md")
        #expect(localTab.isEditable)
        #expect(!transcriptTab().isEditable)
    }
}

// MARK: - Threading through the reducers

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

    @Test func openedTranscriptTabCarriesItsProvenanceAndTitle() throws {
        let (session, terminal) = session()
        let (updated, tabID) = try #require(
            openTranscript(sessionA, path: "/tmp/cache/a.transcript.md", associatedWith: terminal.id, in: session)
        )
        let tab = try #require(updated.layout.firstDocumentGroup?.tab(id: tabID))

        #expect(tab.agentTranscriptIdentity == identity(sessionA))
        #expect(tab.title == "Claude Code Transcript", "the hashed filename is not a usable title")
        #expect(!tab.isEditable)
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

    @Test func reopeningAPlainTabAsATranscriptBackfillsProvenance() throws {
        let (session, terminal) = session()
        let path = "/tmp/cache/a.transcript.md"
        let (afterPlain, plainID) = try #require(
            PaneLayoutReducer.openDocumentTab(
                fileURL: URL(fileURLWithPath: path),
                associatedTerminalPaneID: terminal.id,
                in: session,
                now: Date()
            )
        )
        #expect(afterPlain.layout.firstDocumentGroup?.tab(id: plainID)?.isEditable == true)

        let (afterTranscript, tabID) = try #require(
            openTranscript(sessionA, path: path, associatedWith: terminal.id, in: afterPlain)
        )

        #expect(tabID == plainID)
        let tab = try #require(afterTranscript.layout.firstDocumentGroup?.tab(id: tabID))
        #expect(tab.agentTranscriptIdentity == identity(sessionA))
        #expect(tab.title == "Claude Code Transcript")
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

    @Test func restoreRemintCarriesTranscriptProvenance() throws {
        let tab = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/cache/a.transcript.md"),
            title: "Claude Code Transcript",
            agentTranscriptIdentity: identity(sessionA)
        )
        let layout = TerminalPaneLayout.documentGroup(
            DocumentGroup(tabs: [tab], selectedTabID: tab.id)
        )
        var seenSplitIDs: Set<TerminalSplit.ID> = []
        // Force the collision branch: the tab id is already in the shared pool.
        var seenPaneIDs: Set<TerminalPane.ID> = [tab.id]
        var seenTerminalSessionIDs: Set<TerminalSessionID> = []

        let result = SessionRestoreReducer.restoredLayout(
            from: layout,
            seenSplitIDs: &seenSplitIDs,
            seenPaneIDs: &seenPaneIDs,
            seenTerminalSessionIDs: &seenTerminalSessionIDs,
            transformPane: { $0 }
        )

        let reminted = try #require(result.layout.firstDocumentGroup?.tabs.first)
        #expect(reminted.id != tab.id, "the collision branch must have run")
        #expect(reminted.agentTranscriptIdentity == identity(sessionA))
        #expect(!reminted.isEditable)
    }

    @Test func recentlyClosedReopenCarriesTranscriptProvenance() throws {
        let tab = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/cache/a.transcript.md"),
            title: "Claude Code Transcript",
            agentTranscriptIdentity: identity(sessionA)
        )
        let layout = TerminalPaneLayout.documentGroup(
            DocumentGroup(tabs: [tab], selectedTabID: tab.id)
        )
        var seenTerminalSessionIDs: Set<TerminalSessionID> = []
        var seenPaneIDs: Set<TerminalPane.ID> = []

        let reidentified = RecentlyClosedWorkspaceReducer.reidentifiedLayout(
            layout,
            indexHint: 0,
            seenTerminalSessionIDs: &seenTerminalSessionIDs,
            seenPaneIDs: &seenPaneIDs
        )

        let reopened = try #require(reidentified.firstDocumentGroup?.tabs.first)
        #expect(reopened.id != tab.id, "reopened tabs always remint")
        #expect(reopened.agentTranscriptIdentity == identity(sessionA))
    }
}
