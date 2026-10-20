import AwesoMuxCompanionProtocol
import AwesoMuxLocalAPI
import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("Companion pane list")
struct CompanionPaneListTests {
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
        let result = store.companionWorkspaces(scope: .allWorkspaces, terminalPreviewAllowed: true) { id in
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

    @Test func filtersBeforeReadingTerminalContent() throws {
        let first = TerminalSession(title: "First", workingDirectory: "~")
        let second = TerminalSession(title: "Second", workingDirectory: "~")
        let pane = try #require(first.panes.first)
        let store = SessionStore(groups: [SessionGroup(name: "Work", sessions: [first, second])])
        for scope in [LocalAPITargetScope.persistentPanes([pane.id]), .persistentWorkspaces([first.id])] {
            var reads: [UUID] = []
            let result = store.companionWorkspaces(scope: scope, terminalPreviewAllowed: true) {
                reads.append($0); return "permitted"
            }
            #expect(result.map(\.workspaceID) == [first.id.uuidString])
            #expect(reads == [pane.id])
        }
        let denied = store.companionWorkspaces(scope: .exactTarget(paneID: pane.id, targetVersion: UUID())) { _ in
            Issue.record("Stale target must not read viewport")
            return "private"
        }
        #expect(denied.isEmpty)
    }

    @Test func deniedPhoneGetsRosterWithoutInvokingReader() {
        let session = TerminalSession(title: "Work", workingDirectory: "~")
        let store = SessionStore(groups: [SessionGroup(name: "Work", sessions: [session])])
        let roster = store.companionWorkspaces(scope: .allWorkspaces) { _ in
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
