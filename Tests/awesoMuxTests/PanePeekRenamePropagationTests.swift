import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite
struct PanePeekRenamePropagationTests {
    @MainActor
    @Test
    func renameReflectsInPeekItems() throws {
        let store = SessionStore(groups: [
            SessionGroup(name: "g", sessions: [
                TerminalSession(title: "shell", workingDirectory: "~")
            ])
        ])
        let session = try #require(store.groups.first?.sessions.first)
        // Split so the workspace has 2 panes (the peek card lists per-pane rows).
        store.splitActivePane(orientation: .vertical, in: session.id)

        let updated = try #require(store.session(id: session.id))
        let targetPaneID = updated.activePaneID
        store.renamePane(sessionID: session.id, paneID: targetPaneID, title: "My Backend")

        let items = PanePeekItem.items(for: try #require(store.session(id: session.id)))
        let renamed = try #require(items.first { $0.id == targetPaneID })
        #expect(renamed.title == "My Backend")
    }
}
