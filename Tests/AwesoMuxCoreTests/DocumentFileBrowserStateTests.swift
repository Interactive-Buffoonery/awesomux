import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct DocumentFileBrowserStateTests {
    @Test func opensBrowserWithoutCreatingADocument() throws {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        let session = TerminalSession(
            title: "s",
            workingDirectory: "/tmp",
            layout: .pane(terminal),
            activePaneID: terminal.id
        )

        let opened = try #require(PaneLayoutReducer.openFileBrowser(in: session))
        let repeated = PaneLayoutReducer.openFileBrowser(in: opened)
        let group = try #require(opened.layout.firstDocumentGroup)

        #expect(repeated == nil)
        #expect(group.tabs.isEmpty)
        #expect(group.selectedTabID == nil)
        #expect(group.browserSourcePaneID == terminal.id)
        #expect(opened.activePaneID == terminal.id)
        #expect(opened.layout.paneIDs == session.layout.paneIDs)
        guard case let .split(split) = opened.layout else {
            Issue.record("expected a terminal|browser split")
            return
        }
        #expect(split.orientation == .vertical)
        #expect(split.firstFraction == 0.6)
    }

    @Test func refusesBrowserForAnActiveRemoteTerminal() {
        let terminal = TerminalPane(
            title: "remote",
            workingDirectory: "/repo",
            executionPlan: .ssh(SSHExecution(target: RemoteTarget(parsing: "host")!))
        )
        let session = TerminalSession(
            title: "s",
            workingDirectory: "/repo",
            layout: .pane(terminal),
            activePaneID: terminal.id
        )

        #expect(PaneLayoutReducer.openFileBrowser(in: session) == nil)
    }

    @Test func firstDocumentPromotesBrowserInPlace() throws {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        let session = TerminalSession(
            title: "s",
            workingDirectory: "/tmp",
            layout: .pane(terminal),
            activePaneID: terminal.id
        )
        let browsing = try #require(PaneLayoutReducer.openFileBrowser(in: session))
        let browserID = try #require(browsing.layout.firstDocumentGroup?.id)
        let opened = try #require(
            PaneLayoutReducer.openDocumentTab(
                fileURL: URL(fileURLWithPath: "/tmp/notes.md"),
                associatedTerminalPaneID: terminal.id,
                in: browsing,
                now: Date(),
                selectingNewTab: false
            ))
        let group = try #require(opened.session.layout.firstDocumentGroup)

        #expect(group.id == browserID)
        #expect(group.tabs.map(\.id) == [opened.newTabID])
        #expect(group.selectedTabID == opened.newTabID)
        #expect(group.browserSourcePaneID == nil)
    }

    @Test func recycledBrowserSourcePromotesWithReplacementAssociation() throws {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        let session = TerminalSession(
            title: "s",
            workingDirectory: "/tmp",
            layout: .pane(terminal),
            activePaneID: terminal.id
        )
        let browsing = try #require(PaneLayoutReducer.openFileBrowser(in: session))
        let recycled = try #require(PaneLayoutReducer.recycleActivePane(in: browsing, now: Date()))
        let replacementID = recycled.session.activePaneID
        let sourcePaneID = try #require(recycled.session.layout.firstDocumentGroup?.browserSourcePaneID)
        #expect(sourcePaneID == replacementID)
        let opened = try #require(
            PaneLayoutReducer.openDocumentTab(
                fileURL: URL(fileURLWithPath: "/tmp/notes.md"),
                associatedTerminalPaneID: sourcePaneID,
                in: recycled.session,
                now: Date(),
                selectingNewTab: false
            ))

        let tab = try #require(opened.session.layout.firstDocumentGroup?.tab(id: opened.newTabID))
        #expect(tab.associatedTerminalPaneID == replacementID)
    }

    @Test func closeRemovesOnlyAnEmptyBrowserGroup() throws {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        let session = TerminalSession(
            title: "s",
            workingDirectory: "/tmp",
            layout: .pane(terminal),
            activePaneID: terminal.id
        )
        let browsing = try #require(PaneLayoutReducer.openFileBrowser(in: session))
        let closed = try #require(PaneLayoutReducer.closeFileBrowser(in: browsing))

        #expect(closed.layout == session.layout)
        #expect(PaneLayoutReducer.closeFileBrowser(in: closed) == nil)
    }

    @Test func persistencePrunesBrowserOnlyGroups() throws {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        let browser = DocumentGroup(browsingFrom: terminal.id)
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical,
                first: .pane(terminal),
                second: .documentGroup(browser),
                firstFraction: 0.6
            ))

        let decoded = try JSONDecoder().decode(
            TerminalPaneLayout.self,
            from: JSONEncoder().encode(layout)
        )
        #expect(decoded == .pane(terminal))
        #expect(throws: EncodingError.self) {
            _ = try JSONEncoder().encode(TerminalPaneLayout.documentGroup(browser))
        }
        #expect(throws: EncodingError.self) {
            _ = try JSONEncoder().encode(browser)
        }
    }

    @Test func browserOnlyGroupHasFilesLabelAndNoLocalFileAccess() {
        let browser = DocumentGroup(browsingFrom: TerminalPane.ID())
        let leaf = WorkspaceLeaf.documentGroup(browser)

        #expect(leaf.label == "Files")
        #expect(!leaf.capabilities.localFileAccess)
    }

    @Test func restoreAndRecentlyClosedCaptureDropBrowserOnlyGroups() throws {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        let session = TerminalSession(
            title: "s",
            workingDirectory: "/tmp",
            layout: .pane(terminal),
            activePaneID: terminal.id
        )
        let browsing = try #require(PaneLayoutReducer.openFileBrowser(in: session))
        let group = SessionGroup(name: "main", sessions: [browsing])
        let captured = RecentlyClosedWorkspaceReducer.captureDecision(
            session: browsing,
            group: group,
            indexInGroup: 0,
            now: Date()
        )
        let restored = SessionRestoreReducer.restoredComponents(
            from: SessionSnapshot(
                groups: [group],
                selectedSessionID: browsing.id
            ))

        #expect(captured.entry.layout == .pane(terminal))
        #expect(restored.groups[0].sessions[0].layout.firstDocumentGroup == nil)
        #expect(restored.groups[0].sessions[0].layout.paneIDs == [terminal.id])
    }

    @Test func pruningNestedBrowserPreservesSurvivingSplitIdentity() throws {
        let first = TerminalPane(title: "first", workingDirectory: "/tmp", executionPlan: .local)
        let second = TerminalPane(title: "second", workingDirectory: "/tmp", executionPlan: .local)
        let innerID = TerminalSplit.ID()
        let outerID = TerminalSplit.ID()
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                id: outerID,
                orientation: .horizontal,
                first: .pane(first),
                second: .split(
                    TerminalSplit(
                        id: innerID,
                        orientation: .vertical,
                        first: .pane(second),
                        second: .documentGroup(DocumentGroup(browsingFrom: second.id)),
                        firstFraction: 0.6
                    )),
                firstFraction: 0.4
            ))

        let pruned = try #require(layout.removingBrowserOnlyGroups())
        guard case let .split(split) = pruned else {
            Issue.record("expected outer split to survive")
            return
        }
        #expect(split.id == outerID)
        #expect(split.firstFraction == 0.4)
        #expect(split.first == .pane(first))
        #expect(split.second == .pane(second))
    }

    @Test func foldingAllEmptyGroupsRetainsTheFirstGroup() throws {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        var first = DocumentGroup(browsingFrom: terminal.id)
        first.browserSourcePaneID = nil
        let second = DocumentGroup(browsingFrom: terminal.id)
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .horizontal,
                first: .documentGroup(first),
                second: .documentGroup(second)
            ))

        let folded = DocumentGroupMigration.foldingDocumentGroups(in: layout)
        let group = try #require(folded.firstDocumentGroup)
        #expect(group.id == first.id)
        #expect(group.tabs.isEmpty)
        #expect(group.browserSourcePaneID == nil)
        #expect(folded == .documentGroup(first))
    }

    @Test func foldingMixedEmptyAndRealGroupsPromotesTheRealTab() throws {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        let empty = DocumentGroup(browsingFrom: terminal.id)
        let tab = DocumentPane(fileURL: URL(fileURLWithPath: "/tmp/notes.md"), title: "notes.md")
        let real = DocumentGroup(tabs: [tab], selectedTabID: tab.id)
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .horizontal,
                first: .documentGroup(empty),
                second: .documentGroup(real)
            ))

        let group = try #require(DocumentGroupMigration.foldingDocumentGroups(in: layout).firstDocumentGroup)
        #expect(group.id == empty.id)
        #expect(group.tabs == [tab])
        #expect(group.selectedTabID == tab.id)
        #expect(group.browserSourcePaneID == nil)
    }

    @Test func directReopenPrunesBrowserOnlyGroups() throws {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical,
                first: .pane(terminal),
                second: .documentGroup(DocumentGroup(browsingFrom: terminal.id)),
                firstFraction: 0.6
            ))
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "closed",
            isTitleUserEdited: true,
            agentKind: .shell,
            layout: layout,
            activePaneID: terminal.id,
            groupID: UUID(),
            groupName: "main",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date()
        )
        var groups: [SessionGroup] = []
        var recentlyClosed = [entry]
        var transient: RecentlyClosedWorkspace?

        let reopenedID = RecentlyClosedWorkspaceReducer.reopenMostRecentlyClosed(
            in: &groups,
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &transient,
            now: Date()
        )
        let reopened = try #require(groups.first?.sessions.first)
        #expect(reopenedID == reopened.id)
        #expect(reopened.layout.firstDocumentGroup == nil)
    }

    @MainActor @Test func facadeTargetsOnlyTheExplicitSession() throws {
        let first = TerminalSession(title: "first", workingDirectory: "/tmp")
        let second = TerminalSession(title: "second", workingDirectory: "/tmp")
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [first, second])])

        #expect(store.openFileBrowser(in: second.id))
        #expect(store.session(id: first.id)?.layout.firstDocumentGroup == nil)
        #expect(store.session(id: second.id)?.layout.firstDocumentGroup?.isBrowserOnly == true)
    }
}
