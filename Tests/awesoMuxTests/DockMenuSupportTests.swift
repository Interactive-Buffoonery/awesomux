import Foundation
import Testing
@testable import awesoMux
@testable import AwesoMuxCore

@Suite("Dock recent-workspace menu labels (INT-633)")
struct DockMenuSupportTests {

    private static func entry(title: String) -> RecentlyClosedWorkspace {
        let pane = TerminalPane(title: title, workingDirectory: NSHomeDirectory(), executionPlan: .local)
        return RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: title,
            isTitleUserEdited: true,
            agentKind: .shell,
            layout: .pane(pane),
            activePaneID: pane.id,
            groupID: UUID(),
            groupName: "g",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date()
        )
    }

    @Test("a titled workspace shows its (trimmed) title")
    func showsTitle() {
        let title = DockRecentWorkspaceMenu.displayTitle(for: Self.entry(title: "  my-project  "))
        #expect(title == "my-project")
    }

    @Test("a blank title falls back to a generic label rather than an empty row")
    func blankTitleFallsBack() {
        let title = DockRecentWorkspaceMenu.displayTitle(for: Self.entry(title: "   "))
        #expect(!title.isEmpty)
        #expect(title != "   ")
    }

    @Test("a bidi-override character in the title is stripped from the menu label")
    func stripsBidiOverride() {
        // U+202E RIGHT-TO-LEFT OVERRIDE — the reopen path sanitizes it; the menu
        // display must too, since stored titles are not sanitized at rest.
        let title = DockRecentWorkspaceMenu.displayTitle(for: Self.entry(title: "safe\u{202E}danger"))
        #expect(!title.contains("\u{202E}"))
    }

    @Test("a generated recent workspace resolves its localized title metadata")
    func generatedWorkspaceUsesLocalizedTitle() throws {
        let bundle = try #require(Self.pseudoLocaleBundle)
        let pane = TerminalPane(title: "shell", workingDirectory: "~", executionPlan: .local)
        let workspace = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "shell 2",
            syntheticTitle: SyntheticSessionTitle(agentKind: .shell, index: 2),
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .pane(pane),
            activePaneID: pane.id,
            groupID: UUID(),
            groupName: "main",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date()
        )

        #expect(
            DockRecentWorkspaceMenu.displayTitle(
                for: workspace,
                bundle: bundle,
                locale: Locale(identifier: "zz")
            ) == "⟦2:⟦shell⟧⟧")
    }

    @Test("the token round-trips the exact workspace it was built with")
    func tokenCarriesWorkspace() {
        let workspace = Self.entry(title: "carried")
        let token = DockRecentWorkspaceToken(workspace: workspace)
        #expect(token.workspace == workspace)
    }

    // MARK: - Open-workspaces section (INT-633 follow-up)

    private static func session(title: String) -> TerminalSession {
        let pane = TerminalPane(title: title, workingDirectory: NSHomeDirectory(), executionPlan: .local)
        return TerminalSession(title: title, workingDirectory: "~", layout: .pane(pane))
    }

    @Test("open-workspace rows flatten groups in sidebar order")
    func openRowsFollowStoreOrder() {
        let a = Self.session(title: "a")
        let b = Self.session(title: "b")
        let c = Self.session(title: "c")
        let groups = [
            SessionGroup(name: "g1", sessions: [a, b]),
            SessionGroup(name: "g2", sessions: [c]),
        ]
        let rows = DockRecentWorkspaceMenu.openWorkspaceRows(
            groups: groups,
            pinnedSessionIDs: [],
            activeID: nil
        )
        #expect(rows.map(\.sessionID) == [a.id, b.id, c.id])
        #expect(rows.map(\.title) == ["a", "b", "c"])
    }

    @Test("pinned workspaces lead the open-workspace rows in pin order")
    func openRowsPlacePinnedFirst() {
        let a = Self.session(title: "a")
        let b = Self.session(title: "b")
        let c = Self.session(title: "c")
        let groups = [
            SessionGroup(name: "g1", sessions: [a, b]),
            SessionGroup(name: "g2", sessions: [c]),
        ]
        let rows = DockRecentWorkspaceMenu.openWorkspaceRows(
            groups: groups,
            pinnedSessionIDs: [c.id, a.id],
            activeID: nil
        )
        #expect(rows.map(\.sessionID) == [c.id, a.id, b.id])
    }

    @Test("open-workspace titles are sanitized")
    func openRowsSanitizeTitles() {
        let session = Self.session(title: "safe\u{202E}danger")
        let rows = DockRecentWorkspaceMenu.openWorkspaceRows(
            groups: [SessionGroup(name: "g", sessions: [session])],
            pinnedSessionIDs: [],
            activeID: nil
        )
        #expect(rows.count == 1)
        #expect(!rows[0].title.contains("\u{202E}"))
    }

    @Test("the active workspace is the only row marked active")
    func openRowsMarkActive() {
        let a = Self.session(title: "a")
        let b = Self.session(title: "b")
        let rows = DockRecentWorkspaceMenu.openWorkspaceRows(
            groups: [SessionGroup(name: "g", sessions: [a, b])],
            pinnedSessionIDs: [],
            activeID: b.id
        )
        #expect(rows.filter(\.isActive).map(\.sessionID) == [b.id])
    }

    @Test("an empty store yields no open-workspace rows")
    func openRowsEmptyStore() {
        #expect(DockRecentWorkspaceMenu.openWorkspaceRows(groups: [], pinnedSessionIDs: [], activeID: nil).isEmpty)
    }

    @Test("the open-workspace token round-trips its session id")
    func openTokenCarriesSessionID() {
        let id = UUID()
        #expect(DockOpenWorkspaceToken(sessionID: id).sessionID == id)
    }

    // Pins the seam the Dock action guards against: the store neither
    // validates a direct stale selectedSessionID assignment nor resolves a
    // session for it, so a menu item clicked after its workspace closed would
    // render the no-selection state. If the store ever becomes self-healing
    // here, this test tells you the guard in dockSelectOpenWorkspace can go.
    @Test("a stale session id resolves to no session and no selection")
    @MainActor
    func staleSelectionIsNotHealedByTheStore() {
        let session = Self.session(title: "live")
        let store = SessionStore(groups: [SessionGroup(name: "g", sessions: [session])])
        let staleID = UUID()
        #expect(store.session(id: staleID) == nil)
        store.selectedSessionID = staleID
        #expect(store.selectedSession == nil)
    }

    private static var pseudoLocaleBundle: Bundle? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(
                path: "Fixtures/INT612Localization.bundle/zz.lproj",
                directoryHint: .isDirectory
            )
        return Bundle(url: url)
    }
}
