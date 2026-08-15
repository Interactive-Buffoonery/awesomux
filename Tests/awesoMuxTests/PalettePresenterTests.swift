import AwesoMuxCore
import AwesoMuxTestSupport
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
            isSinglePane: true,
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
        #expect(invocation?.selectionScope == command.selectionScope)
        #expect(invocation?.workspaceTarget == target)
    }

    @Test("command invocation scopes resolve against the captured selection")
    @MainActor
    func commandInvocationScopesResolveAgainstSelection() {
        let session = TerminalSession(title: "storage title", workingDirectory: "/tmp")
        let target = PaletteWorkspaceActionTarget(
            sessionID: session.id,
            activePaneID: session.activePaneID,
            isSinglePane: true,
            selectedDocumentTabID: nil,
            displayedTitle: "displayed title"
        )
        let workspaceInvocation = PaletteCommandInvocation(
            commandID: KeyboardShortcutCatalog.closeWorkspace.id,
            selectionScope: .workspace,
            workspaceTarget: target
        )
        #expect(
            workspaceInvocation.canResolveAgainstCurrentSelection(
                sessionID: session.id,
                paneID: session.activePaneID,
                documentTabID: nil
            ))
        #expect(
            !workspaceInvocation.canResolveAgainstCurrentSelection(
                sessionID: TerminalSession.ID(),
                paneID: session.activePaneID,
                documentTabID: nil
            ))
        #expect(
            !workspaceInvocation.canResolveAgainstCurrentSelection(
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
            paneInvocation.canResolveAgainstCurrentSelection(
                sessionID: session.id,
                paneID: session.activePaneID,
                documentTabID: nil,
                isSinglePane: true
            ))
        #expect(
            !paneInvocation.canResolveAgainstCurrentSelection(
                sessionID: session.id,
                paneID: TerminalPane.ID(),
                documentTabID: nil,
                isSinglePane: true
            ))
        #expect(
            !paneInvocation.canResolveAgainstCurrentSelection(
                sessionID: session.id,
                paneID: session.activePaneID,
                documentTabID: nil,
                isSinglePane: false
            ))

        let documentTabID = DocumentPane.ID()
        let documentInvocation = PaletteCommandInvocation(
            commandID: KeyboardShortcutCatalog.closeDocumentTab.id,
            selectionScope: .documentTab,
            workspaceTarget: PaletteWorkspaceActionTarget(
                sessionID: session.id,
                activePaneID: session.activePaneID,
                isSinglePane: true,
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

    @Test("workspace palette actions preserve their title provenance")
    func workspacePaletteActionsPreserveTitleProvenance() throws {
        let path = "Sources/awesoMux/App/AwesoMuxApp.swift"
        let source = try SourceContract.source(at: path)
        let body = try SourceContract.declarationBody(
            after: "private func runPaletteCommand(_ invocation:",
            in: source,
            path: path
        )
        let scopeGuard = try #require(body.range(of: "invocation.canResolveAgainstCurrentSelection"))
        let workspaceCases = try #require(body.range(of: "if let target = invocation.workspaceTarget"))
        #expect(scopeGuard.lowerBound < workspaceCases.lowerBound)
        let renameCase = try #require(
            body.split(separator: "case KeyboardShortcutCatalog.renameWorkspace.id:", maxSplits: 1)
                .last?.split(
                    separator: "case KeyboardShortcutCatalog.closeWorkspace.id:",
                    maxSplits: 1
                ).first
        )
        let closeCase = try #require(
            body.split(separator: "case KeyboardShortcutCatalog.closeWorkspace.id:", maxSplits: 1)
                .last?.split(
                    separator: "case KeyboardShortcutCatalog.clearWorkspace.id:",
                    maxSplits: 1
                ).first
        )
        let clearCase = try #require(
            body.split(separator: "case KeyboardShortcutCatalog.clearWorkspace.id:", maxSplits: 1)
                .last?.split(separator: "default:", maxSplits: 1).first
        )

        #expect(renameCase.contains("requestRenameWorkspace(session)"))
        #expect(!renameCase.contains("target.displayedTitle"))
        #expect(closeCase.contains("session.title = target.displayedTitle"))
        #expect(clearCase.contains("session.title = target.displayedTitle"))
        #expect(renameCase.contains("signalPaletteTargetUnavailable()"))
        #expect(closeCase.contains("signalPaletteTargetUnavailable()"))
        #expect(clearCase.contains("signalPaletteTargetUnavailable()"))
        #expect(body.contains("guard runPaletteCommand(id: invocation.commandID) else"))

        let renameRequest = try SourceContract.declarationBody(
            after: "private func requestRenameWorkspace(_ session:",
            in: source,
            path: path
        )
        #expect(renameRequest.contains("sessionStore.session(id: session.id)"))
        #expect(renameRequest.contains("title: currentSession.title"))

        let presenterBody = try SourceContract.declarationBody(
            after: "private func makeCommandPalettePresenter()",
            in: source,
            path: path
        )
        #expect(presenterBody.contains("signalPaletteTargetUnavailable()"))
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
            isSinglePane: true,
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
