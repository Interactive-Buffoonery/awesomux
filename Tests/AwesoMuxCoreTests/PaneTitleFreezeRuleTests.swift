import Foundation
import Testing
@testable import AwesoMuxCore

@Suite
struct PaneTitleFreezeRuleTests {
    private func session(title: String = "shell") -> TerminalSession {
        TerminalSession(title: title, workingDirectory: "~")
    }

    @Test
    func frozenPaneIgnoresLiveTitle() throws {
        var s = session()
        let paneID = s.activePaneID
        s = try #require(PaneLayoutReducer.renamePane(in: s, paneID: paneID, title: "My Backend"))
        // A later OSC title must NOT overwrite the custom name.
        s = try #require(PaneLayoutReducer.updatePane(
            in: s, paneID: paneID, title: "zsh", workingDirectory: nil, localHostnames: []
        ))
        #expect(s.layout.pane(id: paneID)?.title == "My Backend")
        #expect(s.layout.pane(id: paneID)?.isTitleUserEdited == true)
    }

    @Test
    func resetClearsFlagAndReadoptsLiveTitle() throws {
        var s = session()
        let paneID = s.activePaneID
        s = try #require(PaneLayoutReducer.updatePane(
            in: s, paneID: paneID, title: "claude", workingDirectory: nil, localHostnames: []
        ))
        s = try #require(PaneLayoutReducer.renamePane(in: s, paneID: paneID, title: "My Backend"))
        // While frozen the live title keeps being cached.
        s = try #require(PaneLayoutReducer.updatePane(
            in: s, paneID: paneID, title: "zsh", workingDirectory: nil, localHostnames: []
        ))
        s = try #require(PaneLayoutReducer.resetPaneTitle(in: s, paneID: paneID))
        #expect(s.layout.pane(id: paneID)?.isTitleUserEdited == false)
        #expect(s.layout.pane(id: paneID)?.title == "zsh")
    }

    @Test
    func renameRejectsBlankTitle() {
        let s = session()
        #expect(PaneLayoutReducer.renamePane(in: s, paneID: s.activePaneID, title: "   ") == nil)
    }

    // MARK: - Lone-pane carve-out (agent renames must be visible)

    @Test
    func lonePinnedPaneWorkspaceTitleIgnoresLaterLiveTitle() throws {
        var s = session(title: "claude")
        let paneID = s.activePaneID
        s = try #require(PaneLayoutReducer.renamePane(in: s, paneID: paneID, title: "My Backend"))
        // A later OSC title keeps being cached for reset, but must not clobber
        // the pinned workspace title while the pane stays lone + pinned.
        s = try #require(PaneLayoutReducer.updatePane(
            in: s, paneID: paneID, title: "zsh", workingDirectory: nil, localHostnames: []
        ))
        #expect(s.title == "My Backend")
        #expect(s.layout.pane(id: paneID)?.liveTerminalTitle == "zsh")
    }

    @Test
    func userRenamedWorkspaceStillWinsOverLonePaneRename() throws {
        var s = session(title: "My Workspace")
        s.isTitleUserEdited = true
        let paneID = s.activePaneID
        s = try #require(PaneLayoutReducer.renamePane(in: s, paneID: paneID, title: "My Backend"))
        // The pane pin lands, but the user's explicit workspace name wins.
        #expect(s.layout.pane(id: paneID)?.title == "My Backend")
        #expect(s.title == "My Workspace")
    }

    @Test(
        "split and recycle never leak a custom name",
        arguments: [
            (false, false), (false, true), (true, false), (true, true),
        ])
    func newPaneTitle(restored: Bool, recycle: Bool) throws {
        var source: TerminalSession
        if restored {
            var pane = TerminalPane(title: "My Backend", workingDirectory: "~/Development/awesomux", executionPlan: .local)
            pane.isTitleUserEdited = true
            source = TerminalSession(title: "ws", workingDirectory: "~", layout: .pane(pane))
        } else {
            source = session(title: "claude")
            let id = source.activePaneID
            source = try #require(
                PaneLayoutReducer.updatePane(in: source, paneID: id, title: "zsh", workingDirectory: nil, localHostnames: []))
            source = try #require(PaneLayoutReducer.renamePane(in: source, paneID: id, title: "My Backend"))
        }
        let result: TerminalSession
        if recycle {
            result = try #require(PaneLayoutReducer.recycleActivePane(in: source, now: Date())).session
        } else {
            result = try #require(PaneLayoutReducer.splitActivePane(in: source, orientation: .vertical, now: Date())).session
        }
        let pane = try #require(result.activePane)
        #expect(pane.title == (restored ? "awesomux" : "zsh"))
        #expect(!pane.isTitleUserEdited)
        #expect(result.title != "My Backend")
    }
}
