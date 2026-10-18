import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite
struct TerminalPaneTitleEditFlagTests {

    /// The carve-out must NOT clobber a user-renamed workspace on restore.
    @Test
    func restoreKeepsUserRenamedWorkspaceTitleOverLonePanePin() throws {
        var pane = TerminalPane(title: "My Backend", workingDirectory: "~/Development/awesomux", executionPlan: .local)
        pane.isTitleUserEdited = true
        var session = TerminalSession(title: "My Workspace", workingDirectory: "~", layout: .pane(pane))
        session.isTitleUserEdited = true
        let group = SessionGroup(name: "g", sessions: [session])
        let snapshot = SessionSnapshot(groups: [group], selectedSessionID: session.id)

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try SessionSnapshot.decode(from: data)
        let restored = SessionRestoreReducer.restoredComponents(from: decoded)

        let restoredSession = try #require(restored.groups.first?.sessions.first)
        #expect(restoredSession.title == "My Workspace")
        #expect(restoredSession.isTitleUserEdited == true)
    }

    enum Reconstruction: Sendable { case restore, duplicateID, reopen, split }

    @Test("frozen titles survive each reconstruction site", arguments: [Reconstruction.restore, .duplicateID, .reopen, .split])
    func reconstructedFrozenTitle(site: Reconstruction) throws {
        var frozen = TerminalPane(title: "My Backend", workingDirectory: "~/Development/awesomux", executionPlan: .local)
        frozen.isTitleUserEdited = true
        let live = TerminalPane(id: site == .duplicateID ? frozen.id : UUID(), title: "other", workingDirectory: "~", executionPlan: .local)
        let layout: TerminalPaneLayout
        if site == .reopen {
            var seenDaemons: Set<TerminalSessionID> = []
            var seenPanes: Set<TerminalPane.ID> = []
            layout = RecentlyClosedWorkspaceReducer.reidentifiedLayout(
                .pane(frozen), indexHint: 1, seenTerminalSessionIDs: &seenDaemons, seenPaneIDs: &seenPanes)
        } else {
            let session = TerminalSession(
                title: "ws", workingDirectory: "~",
                layout: site == .split
                    ? .split(TerminalSplit(orientation: .vertical, first: .pane(frozen), second: .pane(live))) : .pane(frozen))
            let other = TerminalSession(title: "a", workingDirectory: "~", layout: .pane(live))
            let snapshot = SessionSnapshot(
                groups: [SessionGroup(name: "g", sessions: site == .duplicateID ? [other, session] : [session])],
                selectedSessionID: session.id)
            let decoded = try SessionSnapshot.decode(from: JSONEncoder().encode(snapshot))
            let restored = SessionRestoreReducer.restoredComponents(from: decoded)
            let restoredSession = try #require(restored.groups.first?.sessions.last)
            layout = restoredSession.layout
            if site == .restore {
                #expect(restoredSession.title == "My Backend")
            }
        }
        var panes: [TerminalPane] = []
        layout.forEachPane { panes.append($0) }
        let rebuilt = try #require(panes.first { $0.title == "My Backend" })
        #expect(rebuilt.isTitleUserEdited)
        if site == .duplicateID {
            #expect(rebuilt.id != frozen.id)
        }
        if site == .split {
            #expect(layout.pane(id: live.id)?.isTitleUserEdited == false)
        }
    }

    @Test("a sanitized-away pin is released during reconstruction", arguments: [false, true])
    func sanitizedPin(reopen: Bool) throws {
        var frozen = TerminalPane(title: "\u{200B}\u{FEFF}", workingDirectory: "~", executionPlan: .local)
        frozen.isTitleUserEdited = true
        let layout: TerminalPaneLayout
        if reopen {
            var seenDaemons: Set<TerminalSessionID> = []
            var seenPanes: Set<TerminalPane.ID> = []
            layout = RecentlyClosedWorkspaceReducer.reidentifiedLayout(
                .pane(frozen), indexHint: 1, seenTerminalSessionIDs: &seenDaemons, seenPaneIDs: &seenPanes)
        } else {
            let session = TerminalSession(title: "ws", workingDirectory: "~", layout: .pane(frozen))
            let snapshot = SessionSnapshot(groups: [SessionGroup(name: "g", sessions: [session])], selectedSessionID: session.id)
            layout = try #require(SessionRestoreReducer.restoredComponents(from: snapshot).groups.first?.sessions.first?.layout)
        }
        let pane = try #require(layout.firstPane)
        #expect(!pane.isTitleUserEdited)
        #expect(!pane.title.isEmpty)
        #expect(pane.title != frozen.title)
    }
}
