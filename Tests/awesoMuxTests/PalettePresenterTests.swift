import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("Palette presenter")
struct PalettePresenterTests {
    @Test("empty query submit is a no-op")
    @MainActor
    func emptyQuerySubmitIsNoOp() {
        let session = TerminalSession(
            title: "Main",
            workingDirectory: "/tmp",
            agentKind: .shell,
            agentState: .idle
        )
        var didSelect = false
        var didRun = false
        let presenter = PalettePresenter(
            sessionGroups: [SessionGroup(name: "Code", sessions: [session])],
            commands: [],
            selectSession: { _ in
                didSelect = true
                return true
            },
            runCommand: { _ in
                didRun = true
                return true
            }
        )

        #expect(!presenter.submitSelection())
        #expect(!didSelect)
        #expect(!didRun)
    }

    @Test("disabled stale command does not execute")
    @MainActor
    func disabledCommandDoesNotExecute() {
        var didRunClosure = false
        var didRunCommand = false
        let disabledCommand = PaletteCommand(
            id: "stale",
            title: "Stale Command",
            subtitle: nil,
            keywords: ["stale"],
            shortcut: nil,
            isEnabled: false,
            selectionScope: .none,
            run: {
                didRunCommand = true
            }
        )
        let presenter = PalettePresenter(
            sessionGroups: [],
            commands: [disabledCommand],
            selectSession: { _ in true },
            runCommand: { _ in
                didRunClosure = true
                return true
            }
        )
        let staleResult = PaletteResult.command(PaletteCommandResult(
            commandID: disabledCommand.id,
            title: disabledCommand.title,
            subtitle: nil,
            shortcut: nil,
            score: 0
        ))

        #expect(!presenter.perform(staleResult))
        #expect(!didRunClosure)
        #expect(!didRunCommand)
    }

    @Test("query refreshes cached results")
    @MainActor
    func queryRefreshesCachedResults() {
        let session = TerminalSession(
            title: "Review Branch",
            workingDirectory: "/tmp/awesomux",
            agentKind: .shell,
            agentState: .idle
        )
        let presenter = PalettePresenter(
            sessionGroups: [SessionGroup(name: "Code", sessions: [session])],
            commands: [],
            selectSession: { _ in true },
            runCommand: { _ in true }
        )

        #expect(presenter.currentResults.flattened.count == 1)
        #expect(presenter.selectedIndex == nil)

        presenter.query = "review"

        #expect(presenter.currentResults.flattened.count == 1)
        #expect(presenter.flattenedResults.count == 1)
        #expect(presenter.selectedIndex == 0)
    }

    @Test("query preserves its action-time displayed title snapshot")
    @MainActor
    func queryUsesDisplayedTitleSnapshot() throws {
        let session = TerminalSession(title: "storage title", workingDirectory: "/tmp")
        let presenter = PalettePresenter(
            sessionGroups: [SessionGroup(name: "Code", sessions: [session])],
            sessionTitles: [session.id: "displayed title"],
            commands: [],
            selectSession: { _ in true },
            runCommand: { _ in true }
        )

        presenter.query = "displayed"

        guard case .session(let result)? = presenter.flattenedResults.first else {
            Issue.record("Expected displayed-title result")
            return
        }
        #expect(result.title == "displayed title")
    }

    @Test("command submission carries the palette workspace snapshot")
    @MainActor
    func commandSubmissionCarriesWorkspaceSnapshot() throws {
        let session = TerminalSession(title: "storage title", workingDirectory: "/tmp")
        let target = PaletteWorkspaceActionTarget(
            sessionID: session.id,
            activePaneID: session.activePaneID,
            selectedDocumentTabID: nil,
            displayedTitle: "displayed title"
        )
        let command = PaletteCommand(
            id: KeyboardShortcutCatalog.closeWorkspace.id,
            title: "Close Workspace",
            subtitle: target.displayedTitle,
            keywords: ["close"],
            shortcut: KeyboardShortcutCatalog.closeWorkspace,
            isEnabled: true,
            selectionScope: .workspace,
            run: {}
        )
        var invocation: PaletteCommandInvocation?
        let presenter = PalettePresenter(
            sessionGroups: [SessionGroup(name: "Code", sessions: [session])],
            sessionTitles: [session.id: target.displayedTitle],
            commands: [command],
            workspaceTarget: target,
            selectSession: { _ in true },
            runCommand: {
                invocation = $0
                return true
            }
        )
        presenter.query = "close"
        let result = try #require(
            presenter.flattenedResults.first {
                if case .command = $0 { return true }
                return false
            }
        )

        #expect(presenter.perform(result))
        #expect(invocation?.commandID == command.id)
        #expect(invocation?.workspaceTarget == target)
        let submitted = try #require(invocation)
        #expect(
            submitted.canResolveAgainstCurrentSelection(
                sessionID: session.id,
                paneID: session.activePaneID,
                documentTabID: nil
            ))
        #expect(
            !submitted.canResolveAgainstCurrentSelection(
                sessionID: TerminalSession.ID(),
                paneID: session.activePaneID,
                documentTabID: nil
            ))
        #expect(
            !submitted.canResolveAgainstCurrentSelection(
                sessionID: nil,
                paneID: nil,
                documentTabID: nil
            ))

        let paneInvocation = PaletteCommandInvocation(
            commandID: KeyboardShortcutCatalog.closePane.id,
            selectionScope: .pane,
            workspaceTarget: target
        )
        #expect(
            !paneInvocation.canResolveAgainstCurrentSelection(
                sessionID: session.id,
                paneID: TerminalPane.ID(),
                documentTabID: nil
            ))

        let documentTabID = DocumentPane.ID()
        let documentInvocation = PaletteCommandInvocation(
            commandID: KeyboardShortcutCatalog.closeDocumentTab.id,
            selectionScope: .documentTab,
            workspaceTarget: PaletteWorkspaceActionTarget(
                sessionID: session.id,
                activePaneID: session.activePaneID,
                selectedDocumentTabID: documentTabID,
                displayedTitle: target.displayedTitle
            )
        )
        #expect(
            !documentInvocation.canResolveAgainstCurrentSelection(
                sessionID: session.id,
                paneID: session.activePaneID,
                documentTabID: DocumentPane.ID()
            ))

        let globalInvocation = PaletteCommandInvocation(
            commandID: "openSettings",
            selectionScope: .none,
            workspaceTarget: target
        )
        #expect(
            globalInvocation.canResolveAgainstCurrentSelection(
                sessionID: TerminalSession.ID(),
                paneID: TerminalPane.ID(),
                documentTabID: nil
            ))

        let nilWorkspaceInvocation = PaletteCommandInvocation(
            commandID: "connectViaSSH",
            selectionScope: .workspace,
            workspaceTarget: nil
        )
        #expect(
            nilWorkspaceInvocation.canResolveAgainstCurrentSelection(
                sessionID: nil,
                paneID: nil,
                documentTabID: nil
            ))
        #expect(
            !nilWorkspaceInvocation.canResolveAgainstCurrentSelection(
                sessionID: TerminalSession.ID(),
                paneID: TerminalPane.ID(),
                documentTabID: nil
            ))
    }

    @Test("accessibility announcement includes visible result context")
    @MainActor
    func accessibilityAnnouncementIncludesVisibleContext() {
        let sessionResult = PaletteResult.session(PaletteSessionResult(
            sessionID: TerminalSession.ID(),
            title: "Main",
            subtitle: "awesomux",
            groupName: "Code",
            score: 1
        ))
        let commandResult = PaletteResult.command(PaletteCommandResult(
            commandID: "renameWorkspace",
            title: "Rename Workspace",
            subtitle: "Main",
            shortcut: KeyboardShortcutCatalog.renameWorkspace,
            score: 1
        ))
        let presenter = PalettePresenter(
            sessionGroups: [],
            commands: [],
            selectSession: { _ in true },
            runCommand: { _ in true }
        )

        #expect(
            presenter.accessibilityAnnouncement(for: sessionResult)
                == "Workspace: Main, Group: Code, Directory: awesomux"
        )
        #expect(
            presenter.accessibilityAnnouncement(for: commandResult)
                == "Action: Rename Workspace, Main, Shift Command Key R"
        )
    }

    @Test("quick-run result dispatches requested surface")
    @MainActor
    func quickRunDispatchesRequestedSurface() {
        let session = TerminalSession(title: "Main", workingDirectory: "/tmp")
        let target = PaletteWorkspaceActionTarget(
            sessionID: session.id,
            activePaneID: session.activePaneID,
            selectedDocumentTabID: nil,
            displayedTitle: session.title
        )
        var captured: (PaletteQuickRunInvocation, PaletteQuickRunCommitSurface)?
        let quickRun = PaletteQuickRunResult(
            command: "npm test",
            executable: "npm",
            resolvedExecutablePath: "/usr/bin/npm"
        )
        let presenter = PalettePresenter(
            sessionGroups: [SessionGroup(name: "Code", sessions: [session])],
            commands: [],
            workspaceTarget: target,
            selectSession: { _ in true },
            runCommand: { _ in true },
            runQuickRun: { result, surface in
                captured = (result, surface)
                return true
            }
        )

        #expect(presenter.perform(.quickRun(quickRun), surface: .newTab))
        #expect(captured?.0.result == quickRun)
        #expect(captured?.0.workspaceTarget == target)
        #expect(captured?.1 == .newTab)
        #expect(
            captured?.0.canResolveAgainstCurrentSelection(
                sessionID: session.id,
                paneID: session.activePaneID
            ) == true)
        #expect(
            captured?.0.canResolveAgainstCurrentSelection(
                sessionID: session.id,
                paneID: TerminalPane.ID()
            ) == false)
    }
}
