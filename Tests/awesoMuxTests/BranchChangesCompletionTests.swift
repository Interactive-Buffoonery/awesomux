import Foundation
import Testing

@testable import AwesoMuxCore
@testable import awesoMux

@MainActor
@Suite("Branch changes completion")
struct BranchChangesCompletionTests {

    // MARK: - Fixtures

    /// A render result standing in for one the opener produced. The file is
    /// never created: nothing here reads the bytes back, only whether the write
    /// was claimed as awesoMux's own. Unique per call, because the self-write
    /// registry is a process-wide static shared with every other test.
    private func render(markdown: String) throws -> OpenedBranchChanges {
        OpenedBranchChanges(
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: "awesomux-completion-\(UUID().uuidString).branch-changes.md"),
            identity: try #require(
                BranchChangesIdentity(
                    gitBranch: "feature/x",
                    baseRef: "refs/remotes/origin/main",
                    repositoryName: "awesomux"
                )
            ),
            markdown: markdown
        )
    }

    private func pane(_ title: String) -> TerminalPane {
        TerminalPane(title: title, workingDirectory: "/tmp", executionPlan: .local)
    }

    // MARK: - Self-write registration

    @Test("a superseded run still registers the bytes it put on disk")
    func supersededRunRegistersItsWrite() throws {
        let terminal = pane("zsh")
        let session = TerminalSession(
            title: "s",
            workingDirectory: "/tmp",
            layout: .pane(terminal),
            activePaneID: terminal.id
        )
        let store = SessionStore(groups: [SessionGroup(name: "work", sessions: [session])])
        // Two presses on one pane. The first is no longer the pane's current
        // invocation, but a branch switch between them means it rendered into a
        // DIFFERENT cache slot — so its claim succeeded and its bytes landed.
        let stale = BranchChangesInvocations.begin(paneID: terminal.id)
        _ = BranchChangesInvocations.begin(paneID: terminal.id)

        let result = try render(markdown: "# stale\n")
        var alerts: [BranchChangesFailure] = []
        BranchChangesCompletion.apply(
            .success(result),
            paneID: terminal.id,
            ticket: stale,
            store: store,
            alert: { alerts.append($0) }
        )

        // Everything user-facing stays suppressed...
        #expect(alerts.isEmpty)
        #expect(store.session(id: session.id)?.layout.firstDocumentGroup == nil)
        // ...but an already-open tab on that file must see the rewrite as ours,
        // not as somebody else's edit.
        let context = DocumentPaneView.selfWriteRegistry.context(
            fileURL: result.fileURL,
            onDiskSource: result.markdown
        )
        #expect(context?.isSelfWrite == true)
    }

    @Test("a run whose pane is gone still registers the bytes it put on disk")
    func closedPaneRunRegistersItsWrite() throws {
        // A live workspace that never held the pane, so the scan finds no owner.
        let store = SessionStore(groups: [
            SessionGroup(
                name: "work",
                sessions: [TerminalSession(title: "other", workingDirectory: "/tmp")])
        ])
        let gonePaneID = UUID()
        let ticket = BranchChangesInvocations.begin(paneID: gonePaneID)

        let result = try render(markdown: "# orphaned\n")
        var alerts: [BranchChangesFailure] = []
        BranchChangesCompletion.apply(
            .success(result),
            paneID: gonePaneID,
            ticket: ticket,
            store: store,
            alert: { alerts.append($0) }
        )

        #expect(alerts == [.paneClosed])
        let context = DocumentPaneView.selfWriteRegistry.context(
            fileURL: result.fileURL,
            onDiskSource: result.markdown
        )
        #expect(context?.isSelfWrite == true)
    }

    @Test("a superseded render registers nothing, because it wrote nothing")
    func supersededFailureRegistersNothing() throws {
        let terminal = pane("zsh")
        let store = SessionStore(groups: [
            SessionGroup(
                name: "work",
                sessions: [
                    TerminalSession(
                        title: "s",
                        workingDirectory: "/tmp",
                        layout: .pane(terminal),
                        activePaneID: terminal.id
                    )
                ])
        ])
        let ticket = BranchChangesInvocations.begin(paneID: terminal.id)
        let unwritten = try render(markdown: "# never written\n")

        var alerts: [BranchChangesFailure] = []
        BranchChangesCompletion.apply(
            .failure(.superseded),
            paneID: terminal.id,
            ticket: ticket,
            store: store,
            alert: { alerts.append($0) }
        )

        #expect(alerts.isEmpty, "the run the user is waiting for is the other one")
        #expect(
            DocumentPaneView.selfWriteRegistry.context(
                fileURL: unwritten.fileURL,
                onDiskSource: unwritten.markdown
            ) == nil
        )
    }

    // MARK: - Following the pane

    @Test("the tab follows a pane that moved to another workspace")
    func openFollowsMovedPane() throws {
        let staying = pane("staying")
        let moving = pane("moving")
        let source = TerminalSession(
            title: "source",
            workingDirectory: "/tmp",
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(staying),
                    second: .pane(moving),
                    firstFraction: 0.5
                )
            ),
            activePaneID: moving.id
        )
        let store = SessionStore(groups: [SessionGroup(name: "work", sessions: [source])])
        let movedID = try #require(store.movePaneToNewWorkspace(id: moving.id, in: source.id))
        let ticket = BranchChangesInvocations.begin(paneID: moving.id)

        let result = try render(markdown: "# moved\n")
        var alerts: [BranchChangesFailure] = []
        BranchChangesCompletion.apply(
            .success(result),
            paneID: moving.id,
            ticket: ticket,
            store: store,
            alert: { alerts.append($0) }
        )

        #expect(alerts.isEmpty, "a live pane that only changed workspace is not a closed pane")
        #expect(
            store.session(id: source.id)?.layout.firstDocumentGroup == nil,
            "the tab must not land in the workspace the press came from"
        )
        let group = try #require(store.session(id: movedID)?.layout.firstDocumentGroup)
        let tab = try #require(group.tabs.first)
        #expect(tab.fileURL == result.fileURL)
        #expect(tab.associatedTerminalPaneID == moving.id)
        #expect(tab.branchChangesIdentity == result.identity)
    }

    @Test("the tab opens in the pane's own workspace when it never moved")
    func openLandsInTheOwningWorkspace() throws {
        let terminal = pane("zsh")
        let session = TerminalSession(
            title: "s",
            workingDirectory: "/tmp",
            layout: .pane(terminal),
            activePaneID: terminal.id
        )
        let store = SessionStore(groups: [SessionGroup(name: "work", sessions: [session])])
        let ticket = BranchChangesInvocations.begin(paneID: terminal.id)

        let result = try render(markdown: "# here\n")
        BranchChangesCompletion.apply(
            .success(result),
            paneID: terminal.id,
            ticket: ticket,
            store: store,
            alert: { Issue.record("unexpected failure alert: \($0)") }
        )

        let group = try #require(store.session(id: session.id)?.layout.firstDocumentGroup)
        #expect(group.tabs.map(\.fileURL) == [result.fileURL])
    }
}
