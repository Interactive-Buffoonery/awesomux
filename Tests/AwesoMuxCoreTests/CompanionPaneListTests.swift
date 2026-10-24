import AwesoMuxCompanionProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("Companion pane list")
struct CompanionPaneListTests {
    @Test func firstUnboundReadInitializesExactTargets() throws {
        let session = TerminalSession(title: "Work", workingDirectory: "~")
        let pane = try #require(session.panes.first)
        let store = SessionStore(groups: [SessionGroup(name: "Work", sessions: [session])])
        #expect(store.localAPIInstanceID == nil)
        #expect(store.localAPITargets.isEmpty)
        _ = store.companionWorkspaces { _ in nil }
        let target = try #require(store.localAPITargets[pane.id])
        #expect(target.workspaceID == session.id)
        #expect(target.terminalSessionID == pane.terminalSessionID.rawValue)
        for _ in 0..<2 {
            let roster = store.companionWorkspaces { _ in nil }
            #expect(roster.first?.panes.map(\.paneID) == [pane.id.uuidString])
            #expect(store.localAPITargets[pane.id]?.version == target.version)
        }
    }

    @Test(arguments: [false, true])
    func nativeMutationsInvalidateExactTargetsBeforeAnotherRead(bound: Bool) throws {
        let session = TerminalSession(title: "Work", workingDirectory: "~")
        let pane = try #require(session.panes.first)
        let store = SessionStore(groups: [SessionGroup(name: "Work", sessions: [session])])
        if bound { store.bindLocalAPIInstance(UUID()) }
        _ = store.companionWorkspaces { _ in nil }
        let original = try #require(store.localAPITargets[pane.id]?.version)
        #expect(
            store.applyDetectedAgentState(
                id: session.id, paneID: pane.id, detectedState: nil, agentKind: .codex, clearsAttention: false))
        let providerVersion = try #require(store.localAPITargets[pane.id]?.version)
        #expect(providerVersion != original)
        #expect(store.localAPITargets[pane.id]?.provider == .codex)
        let sibling = try #require(store.splitActivePane(orientation: .horizontal, in: session.id))
        #expect(store.localAPITargets[sibling]?.workspaceID == session.id)
        let movedWorkspace = try #require(store.movePaneToNewWorkspace(id: pane.id, in: session.id))
        let moved = try #require(store.localAPITargets[pane.id])
        #expect(moved.workspaceID == movedWorkspace)
        #expect(moved.version != providerVersion)
        #expect(store.returnPaneToSourceWorkspace(sessionID: movedWorkspace))
        let returned = try #require(store.localAPITargets[pane.id])
        #expect(returned.workspaceID == session.id)
        #expect(returned.version != moved.version)
        let current = store.companionWorkspaces { _ in nil }
        #expect(
            current.flatMap(\.panes).first { $0.paneID == pane.id.uuidString }?.targetVersion == returned.version.uuidString.lowercased())
        #expect(store.closePane(id: pane.id, in: session.id) != nil)
        #expect(store.localAPITargets[pane.id] == nil)
        #expect(store.localAPITargets[sibling] != nil)
    }

    @Test func unboundSameStateRuntimeIdentityUpdatesRosterTarget() throws {
        let session = TerminalSession(title: "Work", workingDirectory: "~")
        let pane = try #require(session.panes.first)
        let store = SessionStore(groups: [SessionGroup(name: "Work", sessions: [session])])
        _ = store.companionWorkspaces { _ in nil }
        #expect(store.localAPIAttentionJournal == nil)
        #expect(
            store.applyAgentRuntimeEvent(
                AgentRuntimeEvent(source: .codex, executionState: .thinking, phase: .promptSubmit, eventID: "anonymous"),
                to: session.id, paneID: pane.id))
        let anonymous = try #require(store.localAPITargets[pane.id])
        let thinking = try #require(store.session(id: session.id)?.layout.pane(id: pane.id))
        #expect(anonymous.providerSessionID == nil)
        #expect(
            store.applyAgentRuntimeEvent(
                AgentRuntimeEvent(
                    source: .codex, executionState: .thinking, phase: .promptSubmit,
                    eventID: "identified", providerSessionID: "identified-session"),
                to: session.id, paneID: pane.id))
        let unchanged = try #require(store.session(id: session.id)?.layout.pane(id: pane.id))
        #expect(unchanged == thinking)
        #expect(unchanged.lastAgentStateChangeAt == thinking.lastAgentStateChangeAt)
        let identified = try #require(store.localAPITargets[pane.id])
        #expect(identified.providerSessionID == "identified-session")
        #expect(identified.version != anonymous.version)
        var reads = 0
        let current = store.companionWorkspaces(terminalPreviewAllowed: true) { _ in
            reads += 1
            return "permitted"
        }
        #expect(current.first?.panes.first?.targetVersion == identified.version.uuidString.lowercased())
        #expect(current.first?.panes.first?.lastOutputLine == "permitted")
        #expect(reads == 1)
    }

    @Test func includesShellsSplitsAndDocumentLeavesInOrder() throws {
        let shell = TerminalPane(title: "Shell", workingDirectory: "~", executionPlan: .local)
        let agent = TerminalPane(title: "Agent", workingDirectory: "~", agentKind: .codex, executionPlan: .local)
        let documents = DocumentGroup(browsingFrom: shell.id)
        let session = TerminalSession(
            title: "Work", workingDirectory: "~",
            layout: .split(
                TerminalSplit(
                    orientation: .vertical, first: .pane(shell),
                    second: .split(
                        TerminalSplit(
                            orientation: .horizontal, first: .pane(agent), second: .documentGroup(documents)
                        ))
                )), activePaneID: shell.id)
        let second = TerminalSession(title: "Second", workingDirectory: "~")
        let store = SessionStore(groups: [SessionGroup(name: "One", sessions: [session]), SessionGroup(name: "Two", sessions: [second])])
        let selection = store.selectedSessionID
        var reads: [UUID] = []
        let result = store.companionWorkspaces(terminalPreviewAllowed: true) { id in
            reads.append(id)
            return CompanionPanePreview.lastLine(in: id == shell.id ? "old\nlast line\n \n" : nil)
        }
        #expect(result.map(\.workspaceID) == [session.id.uuidString, second.id.uuidString])
        #expect(result[0].panes.map(\.paneID) == [shell.id.uuidString, agent.id.uuidString, documents.id.uuidString])
        #expect(result[0].panes.map(\.kind) == ["terminal", "terminal", "documentGroup"])
        #expect(result[0].panes[0].state == shell.agentSnapshot().state.rawValue)
        #expect(result[0].panes[0].availability == PaneAvailability.of(.terminal(shell)).rawValue)
        #expect(result[0].panes[0].lastOutputLine == "last line")
        #expect(result[0].panes[1].lastOutputLine == nil)
        #expect(result[0].panes[2].lastOutputLine == nil)
        #expect(result[0].panes[2].state == nil)
        #expect(!reads.contains(documents.id))
        #expect(store.selectedSessionID == selection)
    }

    @Test func deniedPhoneGetsRosterWithoutInvokingReader() {
        let session = TerminalSession(title: "Work", workingDirectory: "~")
        let store = SessionStore(groups: [SessionGroup(name: "Work", sessions: [session])])
        let roster = store.companionWorkspaces { _ in
            Issue.record("Preview permission must precede even a cached read")
            return "private"
        }
        #expect(roster.count == 1)
        #expect(roster.first?.panes.first?.lastOutputLine == nil)
        #expect(roster.first?.panes.first?.state != nil)
    }

    @Test func previewPreservesWholeGraphemesAndSkipsInvisibleLines() {
        let combining = "q\u{0301}"
        let joinedEmoji = "👩‍💻"
        for character in [combining, joinedEmoji] {
            let input = String(repeating: "x", count: 511) + character
            #expect(CompanionPanePreview.lastLine(in: input) == String(repeating: "x", count: 511))
            let exactPrefix = String(repeating: "x", count: 512 - character.utf8.count)
            #expect(CompanionPanePreview.lastLine(in: exactPrefix + character) == exactPrefix + character)
        }
        #expect(CompanionPanePreview.lastLine(in: "visible\n\u{202E}\u{0007}\n ") == "visible")
        let invisiblePrefix = String(repeating: "\u{200E}", count: 171)
        #expect(CompanionPanePreview.lastLine(in: "visible\n" + invisiblePrefix + "x") == "visible")
        #expect(CompanionPanePreview.lastLine(in: invisiblePrefix + "x") == nil)
    }

    @Test func previewIsOneBoundedUTF8Line() {
        #expect(CompanionPanePreview.lastLine(in: nil) == nil)
        #expect(CompanionPanePreview.lastLine(in: "\n \n") == nil)
        #expect(CompanionPanePreview.lastLine(in: "first\r\nlast\r\n") == "last")
        #expect(CompanionPanePreview.lastLine(in: "safe\u{001B}\u{0007}\u{202E}text") == "safetext")
        #expect(CompanionPanePreview.lastLine(in: "\u{202E}\u{0007}") == nil)
        let line = CompanionPanePreview.lastLine(in: String(repeating: "😀", count: 200))
        #expect(line?.utf8.count == 512)
        #expect(line == String(repeating: "😀", count: 128))
    }
}
