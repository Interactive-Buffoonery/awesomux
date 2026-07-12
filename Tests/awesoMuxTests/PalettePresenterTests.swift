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
        var captured: (PaletteQuickRunResult, PaletteQuickRunCommitSurface)?
        let quickRun = PaletteQuickRunResult(
            command: "npm test",
            executable: "npm",
            resolvedExecutablePath: "/usr/bin/npm"
        )
        let presenter = PalettePresenter(
            sessionGroups: [],
            commands: [],
            selectSession: { _ in true },
            runCommand: { _ in true },
            runQuickRun: { result, surface in
                captured = (result, surface)
                return true
            }
        )

        #expect(presenter.perform(.quickRun(quickRun), surface: .newTab))
        #expect(captured?.0 == quickRun)
        #expect(captured?.1 == .newTab)
    }
}
