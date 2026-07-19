import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("Palette command registry")
struct PaletteCommandRegistryTests {
    @Test("Sidebar visibility title follows persistent hidden intent")
    @MainActor
    func sidebarVisibilityTitleFollowsHiddenIntent() throws {
        let store = SessionStore(groups: [])

        let visibleCommands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: .init(isSidebarHidden: false),
            actions: .noop
        )
        let hiddenCommands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: .init(isSidebarHidden: true),
            actions: .noop
        )

        #expect(
            try #require(
                PaletteCommandRegistry.command(
                    id: KeyboardShortcutCatalog.toggleSidebarVisibility.id,
                    in: visibleCommands
                )
            ).title == "Hide Sidebar"
        )
        #expect(
            try #require(
                PaletteCommandRegistry.command(
                    id: KeyboardShortcutCatalog.toggleSidebarVisibility.id,
                    in: hiddenCommands
                )
            ).title == "Show Sidebar"
        )
    }

    @Test("Unavailable primary target gates sidebar commands")
    @MainActor
    func unavailablePrimaryTargetGatesSidebarCommands() throws {
        let commands = PaletteCommandRegistry.commands(
            sessionStore: SessionStore(groups: []),
            availability: .init(isSidebarCommandTargetAvailable: false),
            actions: .noop)

        for commandID in [
            KeyboardShortcutCatalog.focusSidebar.id,
            KeyboardShortcutCatalog.toggleSidebarWidth.id,
            KeyboardShortcutCatalog.toggleSidebarVisibility.id,
        ] {
            #expect(
                try !#require(
                    PaletteCommandRegistry.command(id: commandID, in: commands)
                ).isEnabled)
        }
    }

    @Test("Registry covers menu-equivalent command IDs")
    @MainActor
    func registryCoversMenuEquivalentCommands() {
        let store = SessionStore(groups: [])
        let commands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: .init(),
            actions: .noop
        )
        let ids = Set(commands.map(\.id))
        let expectedIDs = Set(
            [
                KeyboardShortcutCatalog.newWorkspace.id,
                KeyboardShortcutCatalog.newWorkspaceInCurrentDirectory.id,
                KeyboardShortcutCatalog.newWorkspaceGroup.id,
                "newRemoteWorkspaceGroup",
                "connectViaSSH",
                "makeThisWorkspaceManaged",
                KeyboardShortcutCatalog.renameWorkspace.id,
                KeyboardShortcutCatalog.renamePane.id,
                "resetPaneTitle",
                KeyboardShortcutCatalog.closeWorkspace.id,
                KeyboardShortcutCatalog.clearWorkspace.id,
                KeyboardShortcutCatalog.reopenClosedWorkspace.id,
                KeyboardShortcutCatalog.splitRight.id,
                KeyboardShortcutCatalog.splitDown.id,
                KeyboardShortcutCatalog.closePane.id,
                "restartShell",
                KeyboardShortcutCatalog.find.id,
                KeyboardShortcutCatalog.scrollbackDump.id,
                "reconnectRemotePane",
                KeyboardShortcutCatalog.growActivePane.id,
                KeyboardShortcutCatalog.shrinkActivePane.id,
                KeyboardShortcutCatalog.previousPane.id,
                KeyboardShortcutCatalog.nextPane.id,
                KeyboardShortcutCatalog.previousDocumentTab.id,
                KeyboardShortcutCatalog.nextDocumentTab.id,
                KeyboardShortcutCatalog.closeDocumentTab.id,
                KeyboardShortcutCatalog.movePaneUp.id,
                KeyboardShortcutCatalog.movePaneDown.id,
                KeyboardShortcutCatalog.movePaneLeft.id,
                KeyboardShortcutCatalog.movePaneRight.id,
                KeyboardShortcutCatalog.swapPaneWithNext.id,
            ] + KeyboardShortcutCatalog.focusPaneBindings.map(\.id) + [
                KeyboardShortcutCatalog.acknowledgeWorkspace.id,
                KeyboardShortcutCatalog.focusPermissionPrompt.id,
                "clearAllNotifications",
                KeyboardShortcutCatalog.toggleFloatingPanel.id,
                KeyboardShortcutCatalog.togglePopUpTerminal.id,
                KeyboardShortcutCatalog.toggleCommandPalette.id,
                KeyboardShortcutCatalog.focusSidebar.id,
                KeyboardShortcutCatalog.toggleSidebarWidth.id,
                KeyboardShortcutCatalog.toggleSidebarVisibility.id,
            ] + KeyboardShortcutCatalog.jumpWorkspaces.map(\.id) + [
                KeyboardShortcutCatalog.previousWorkspace.id,
                KeyboardShortcutCatalog.nextWorkspace.id,
                KeyboardShortcutCatalog.togglePinWorkspace.id,
                "recenterPalette",
                "openSettings",
                "openInIDE",
                KeyboardShortcutCatalog.showKeyboardCheatsheet.id,
                KeyboardShortcutCatalog.openMarkdownFile.id,
                KeyboardShortcutCatalog.sessionManager.id,
                "saveLayoutPreset",
                "applyLayoutPreset",
                "createWorktree",
                "openWorktree",
                "manageWorktrees",
            ])

        #expect(commands.map(\.id).count == ids.count)
        #expect(ids == expectedIDs)
    }

    @Test("Worktree manager availability gates worktree commands")
    @MainActor
    func worktreeManagerAvailabilityGatesWorktreeCommands() throws {
        let unavailableCommands = PaletteCommandRegistry.commands(
            sessionStore: SessionStore(groups: []),
            availability: .init(isWorktreeManagerAvailable: false),
            actions: .noop
        )
        let availableCommands = PaletteCommandRegistry.commands(
            sessionStore: SessionStore(groups: []),
            availability: .init(isWorktreeManagerAvailable: true),
            actions: .noop
        )

        for commandID in ["createWorktree", "openWorktree", "manageWorktrees"] {
            #expect(
                try !#require(
                    PaletteCommandRegistry.command(id: commandID, in: unavailableCommands)
                ).isEnabled
            )
            #expect(
                try #require(
                    PaletteCommandRegistry.command(id: commandID, in: availableCommands)
                ).isEnabled
            )
        }
    }

    @Test("No-session store gates session-dependent commands")
    @MainActor
    func noSessionGatesSessionDependentCommands() throws {
        let store = SessionStore(groups: [])
        let commands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: .init(),
            actions: .noop
        )

        let splitRight = try #require(PaletteCommandRegistry.command(id: "splitRight", in: commands))
        let rename = try #require(PaletteCommandRegistry.command(id: "renameWorkspace", in: commands))
        let newWorkspace = try #require(PaletteCommandRegistry.command(id: "newWorkspace", in: commands))
        let openMarkdownFile = try #require(
            PaletteCommandRegistry.command(id: KeyboardShortcutCatalog.openMarkdownFile.id, in: commands)
        )
        let openInIDE = try #require(PaletteCommandRegistry.command(id: "openInIDE", in: commands))

        #expect(!splitRight.isEnabled)
        #expect(!rename.isEnabled)
        #expect(newWorkspace.isEnabled)
        // openMarkdownFile is session-scoped; must be disabled when no session is selected.
        #expect(!openMarkdownFile.isEnabled)
        #expect(!openInIDE.isEnabled)
    }

    @Test("Sheet-presented state gates sheet-sensitive commands")
    @MainActor
    func sheetPresentedGatesCommands() throws {
        let store = SessionStore(groups: [
            SessionGroup(
                name: "Code",
                sessions: [
                    TerminalSession(title: "Main", workingDirectory: "/tmp", agentKind: .shell, agentState: .idle)
                ])
        ])
        let commands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: PaletteCommandAvailability(isAnySheetPresented: true),
            actions: .noop
        )

        let newGroup = try #require(PaletteCommandRegistry.command(id: "newWorkspaceGroup", in: commands))
        let rename = try #require(PaletteCommandRegistry.command(id: "renameWorkspace", in: commands))
        let find = try #require(PaletteCommandRegistry.command(id: "find", in: commands))
        let scrollbackDump = try #require(PaletteCommandRegistry.command(id: "scrollbackDump", in: commands))
        let floating = try #require(PaletteCommandRegistry.command(id: "toggleFloatingPanel", in: commands))
        let cheatsheet = try #require(PaletteCommandRegistry.command(id: "showKeyboardCheatsheet", in: commands))
        let openInIDE = try #require(PaletteCommandRegistry.command(id: "openInIDE", in: commands))

        #expect(!newGroup.isEnabled)
        #expect(!rename.isEnabled)
        #expect(!find.isEnabled)
        #expect(!scrollbackDump.isEnabled)
        #expect(!floating.isEnabled)
        #expect(!cheatsheet.isEnabled)
        #expect(!openInIDE.isEnabled)
    }

    @Test("New Remote Workspace Group command is registered")
    @MainActor
    func remoteWorkspaceGroupCommandIsRegistered() {
        let store = SessionStore(groups: [])
        let commands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: .init(),
            actions: .noop
        )
        #expect(commands.contains { $0.id == "newRemoteWorkspaceGroup" })
    }

    @Test("managed conversion palette action mirrors menu eligibility and exact destination")
    @MainActor
    func managedConversionActionEligibility() throws {
        let pane = TerminalPane(
            title: "ssh",
            workingDirectory: "~",
            remoteHost: "server.example",
            remoteSSHTarget: "deploy@server-alias",
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "ssh",
            workingDirectory: "~",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "Work", sessions: [session])],
            selectedSessionID: session.id
        )

        let command = try #require(
            PaletteCommandRegistry.command(
                id: "makeThisWorkspaceManaged",
                in: PaletteCommandRegistry.commands(
                    sessionStore: store,
                    availability: .init(),
                    actions: .noop
                )
            ))
        #expect(command.title == "Make This Workspace Managed…")
        #expect(command.subtitle == "deploy@server-alias")
        #expect(command.isEnabled)
        #expect(command.shortcut == nil)

        let request = try #require(
            SSHWorkspaceConnectRequest.managedConversion(
                sessionStore: store,
                sessionID: session.id
            )
        )
        #expect(request.initialDestination == "deploy@server-alias")
        switch request.action {
        case .convertPane(let sessionID, let paneID):
            #expect(sessionID == session.id)
            #expect(paneID == pane.id)
        case .addToGroup:
            Issue.record("Expected an in-place pane conversion request")
        }
        if case .some = SSHWorkspaceConnectRequest.managedConversion(
            sessionStore: store,
            sessionID: TerminalSession.ID()
        ) {
            Issue.record("An unselected workspace must not create a conversion request")
        }

        _ = store.consumeManagedSSHWorkspaceOffer(sessionID: session.id, paneID: pane.id)
        let afterDismissal = try #require(
            PaletteCommandRegistry.command(
                id: "makeThisWorkspaceManaged",
                in: PaletteCommandRegistry.commands(
                    sessionStore: store,
                    availability: .init(),
                    actions: .noop
                )
            ))
        #expect(afterDismissal.isEnabled)
        #expect(afterDismissal.subtitle == "deploy@server-alias")

        let withSheet = try #require(
            PaletteCommandRegistry.command(
                id: "makeThisWorkspaceManaged",
                in: PaletteCommandRegistry.commands(
                    sessionStore: store,
                    availability: .init(isAnySheetPresented: true),
                    actions: .noop
                )
            ))
        #expect(!withSheet.isEnabled)
    }

    @Test("Rename Pane is gated to multi-pane workspaces")
    @MainActor
    func renamePaneGatedToMultiPane() throws {
        let store = SessionStore(groups: SessionStore.previewGroups)
        let commands = PaletteCommandRegistry.commands(
            sessionStore: store, availability: .init(), actions: .noop
        )
        let renamePane = try #require(
            PaletteCommandRegistry.command(id: "renamePane", in: commands)
        )
        // Preview workspaces are single-pane, so the command is disabled.
        #expect(!renamePane.isEnabled)
    }

    @Test("Toggle ActionBar is omitted until a real ActionBar exists")
    @MainActor
    func toggleActionBarOmitted() {
        let store = SessionStore(groups: [])
        let commands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: .init(),
            actions: .noop
        )

        #expect(!commands.contains { $0.id == "toggleActionBar" })
    }

    @Test("Shortcut-backed commands use catalog key bindings")
    @MainActor
    func shortcutBackedCommandsUseCatalogBindings() {
        let store = SessionStore(groups: [
            SessionGroup(
                name: "Code",
                sessions: [
                    TerminalSession(title: "Main", workingDirectory: "/tmp", agentKind: .shell, agentState: .idle)
                ])
        ])
        let commands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: .init(),
            actions: .noop
        )
        let catalogBindings = Dictionary(
            uniqueKeysWithValues: KeyboardShortcutCatalog.settingsSections
                .flatMap(\.entries)
                .flatMap(\.bindings)
                .map { ($0.id, $0.displaySymbol) }
        )

        for command in commands where command.shortcut != nil {
            #expect(command.shortcut?.id == command.id)
            #expect(command.shortcut?.displaySymbol == catalogBindings[command.id])
        }
    }

    @Test("Registry covers every cheatsheet shortcut row")
    @MainActor
    func registryCoversEveryCheatsheetShortcutRow() {
        let store = SessionStore(groups: [])
        let commands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: .init(),
            actions: .noop
        )
        let commandIDs = Set(commands.map(\.id))
        let cheatsheetEntryIDs = Set(
            KeyboardShortcutCatalog.settingsSections
                .flatMap(\.entries)
                .map(\.id))

        #expect(cheatsheetEntryIDs.isSubset(of: commandIDs))
    }

    @Test("Open Markdown File advertises command o")
    @MainActor
    func openMarkdownFileAdvertisesCommandO() throws {
        let store = SessionStore(groups: [
            SessionGroup(
                name: "Code",
                sessions: [
                    TerminalSession(title: "Main", workingDirectory: "/tmp", agentKind: .shell, agentState: .idle)
                ])
        ])
        let commands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: .init(),
            actions: .noop
        )

        let openMarkdownFile = try #require(
            PaletteCommandRegistry.command(id: KeyboardShortcutCatalog.openMarkdownFile.id, in: commands)
        )

        #expect(openMarkdownFile.shortcut?.id == KeyboardShortcutCatalog.openMarkdownFile.id)
        #expect(openMarkdownFile.shortcut?.displaySymbol == "⌘O")
    }

    @Test("Open in IDE is active-pane scoped and disables for remote panes")
    @MainActor
    func openInIDEDisablesForRemoteActivePane() throws {
        let localPane = TerminalPane(title: "local", workingDirectory: "/tmp/local", executionPlan: .local)
        let remotePane = TerminalPane(
            title: "remote",
            workingDirectory: "/tmp/stale-local",
            remoteHost: "buildbox",
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "Remote",
            workingDirectory: "/tmp/local",
            agentKind: .shell,
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(localPane),
                    second: .pane(remotePane)
                )),
            activePaneID: remotePane.id
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "Code", sessions: [session])
        ])

        let commands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: .init(),
            actions: .noop
        )

        let openInIDE = try #require(PaletteCommandRegistry.command(id: "openInIDE", in: commands))
        #expect(!openInIDE.isEnabled)
        #expect(openInIDE.shortcut == nil)
    }

    @Test("Open in IDE disables for declared SSH panes before host observation")
    @MainActor
    func openInIDEDisablesForDeclaredSSHPane() throws {
        let target = try #require(RemoteTarget(parsing: "buildbox"))
        let remotePane = TerminalPane(
            title: "remote",
            workingDirectory: "/tmp/stale-local",
            executionPlan: .ssh(SSHExecution(target: target))
        )
        let session = TerminalSession(
            title: "Remote",
            workingDirectory: "/tmp/stale-local",
            agentKind: .shell,
            layout: .pane(remotePane),
            activePaneID: remotePane.id
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "Code", sessions: [session])
        ])

        let commands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: .init(),
            actions: .noop
        )

        let openInIDE = try #require(PaletteCommandRegistry.command(id: "openInIDE", in: commands))
        #expect(!openInIDE.isEnabled)
        #expect(openInIDE.shortcut == nil)
    }

    @Test("Open in IDE respects the workspace setting")
    @MainActor
    func openInIDERespectsWorkspaceSetting() throws {
        let store = SessionStore(groups: [
            SessionGroup(
                name: "Code",
                sessions: [
                    TerminalSession(title: "Local", workingDirectory: "/tmp/local", agentKind: .shell)
                ])
        ])

        let commands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: PaletteCommandAvailability(isOpenInIDEEnabled: false),
            actions: .noop
        )

        let openInIDE = try #require(PaletteCommandRegistry.command(id: "openInIDE", in: commands))
        #expect(!openInIDE.isEnabled)
    }

    @Test("Focus pane and jump workspace commands mirror menu enablement")
    @MainActor
    func dynamicCommandsMirrorMenuEnablement() throws {
        let store = SessionStore(groups: [
            SessionGroup(
                name: "Code",
                sessions: [
                    TerminalSession(title: "One", workingDirectory: "/tmp", agentKind: .shell, agentState: .idle),
                    TerminalSession(title: "Two", workingDirectory: "/tmp", agentKind: .shell, agentState: .idle),
                ])
        ])
        store.selectedSessionID = store.groups[0].sessions[0].id
        store.splitActivePane(orientation: .vertical)

        let commands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: .init(),
            actions: .noop
        )

        #expect(try #require(PaletteCommandRegistry.command(id: "focusPane1", in: commands)).isEnabled)
        #expect(try #require(PaletteCommandRegistry.command(id: "focusPane2", in: commands)).isEnabled)
        #expect(!((try #require(PaletteCommandRegistry.command(id: "focusPane3", in: commands))).isEnabled))

        #expect(try #require(PaletteCommandRegistry.command(id: "jumpWorkspace1", in: commands)).isEnabled)
        #expect(try #require(PaletteCommandRegistry.command(id: "jumpWorkspace2", in: commands)).isEnabled)
        #expect(!((try #require(PaletteCommandRegistry.command(id: "jumpWorkspace3", in: commands))).isEnabled))

        #expect(try #require(PaletteCommandRegistry.command(id: "previousWorkspace", in: commands)).isEnabled)
        #expect(try #require(PaletteCommandRegistry.command(id: "nextWorkspace", in: commands)).isEnabled)

        let selected = try #require(store.selectedSession)
        let moveCases: [(String, PaneMoveEdge)] = [
            ("movePaneUp", .up),
            ("movePaneDown", .down),
            ("movePaneLeft", .left),
            ("movePaneRight", .right),
        ]
        for (commandID, edge) in moveCases {
            let command = try #require(PaletteCommandRegistry.command(id: commandID, in: commands))
            #expect(
                command.isEnabled
                    == store.canMovePane(
                        id: selected.activePaneID,
                        toWorkspaceEdge: edge,
                        in: selected.id
                    ))
        }

        let nextPaneID = try #require(
            selected.layout.paneIDs.first { $0 != selected.activePaneID }
        )
        let swap = try #require(PaletteCommandRegistry.command(id: "swapPaneWithNext", in: commands))
        #expect(
            swap.isEnabled
                == store.canSwapPanes(
                    firstID: selected.activePaneID,
                    secondID: nextPaneID,
                    in: selected.id
                ))
    }

    @Test("Acknowledge command derives enablement from selected session")
    @MainActor
    func acknowledgeCommandDerivesEnablementFromStore() throws {
        let session = TerminalSession(
            title: "Needs me",
            workingDirectory: "/tmp",
            agentKind: .claudeCode,
            agentState: .running
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "Code", sessions: [session])
        ])
        store.markSessionNeedsAttention(id: session.id)

        let commands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: .init(),
            actions: .noop
        )

        #expect(try #require(PaletteCommandRegistry.command(id: "acknowledgeWorkspace", in: commands)).isEnabled)
    }

    @Test("Clear Workspace is registered and gated on selection")
    @MainActor
    func clearWorkspaceGatedOnSelection() throws {
        let emptyStore = SessionStore(groups: [])
        let emptyCommands = PaletteCommandRegistry.commands(
            sessionStore: emptyStore,
            availability: .init(),
            actions: .noop
        )
        let disabled = try #require(
            PaletteCommandRegistry.command(id: KeyboardShortcutCatalog.clearWorkspace.id, in: emptyCommands)
        )
        #expect(!disabled.isEnabled)

        let store = SessionStore(groups: [
            SessionGroup(
                name: "Code",
                sessions: [
                    TerminalSession(title: "Main", workingDirectory: "/tmp", agentKind: .shell, agentState: .idle)
                ])
        ])
        let commands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: .init(),
            actions: .noop
        )
        let enabled = try #require(
            PaletteCommandRegistry.command(id: KeyboardShortcutCatalog.clearWorkspace.id, in: commands)
        )
        #expect(enabled.isEnabled)
    }

    @Test("Close Pane title reads Close Workspace for a single-pane session")
    @MainActor
    func closePaneTitleMatchesLastPaneSemantics() throws {
        let pane = TerminalPane(title: "only", workingDirectory: "/tmp", executionPlan: .local)
        let session = TerminalSession(
            title: "Solo",
            workingDirectory: "/tmp",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "Code", sessions: [session])],
            selectedSessionID: session.id
        )

        let command = try #require(
            PaletteCommandRegistry.command(
                id: KeyboardShortcutCatalog.closePane.id,
                in: PaletteCommandRegistry.commands(
                    sessionStore: store,
                    availability: .init(),
                    actions: .noop
                )
            ))
        #expect(command.title == "Close Workspace")
    }

    @Test("Close Pane title stays Close Pane for a multi-pane session")
    @MainActor
    func closePaneTitleStaysClosePaneWithMultiplePanes() throws {
        let first = TerminalPane(title: "first", workingDirectory: "/tmp", executionPlan: .local)
        let second = TerminalPane(title: "second", workingDirectory: "/tmp", executionPlan: .local)
        let session = TerminalSession(
            title: "Split",
            workingDirectory: "/tmp",
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(first),
                    second: .pane(second)
                )),
            activePaneID: first.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "Code", sessions: [session])],
            selectedSessionID: session.id
        )

        let command = try #require(
            PaletteCommandRegistry.command(
                id: KeyboardShortcutCatalog.closePane.id,
                in: PaletteCommandRegistry.commands(
                    sessionStore: store,
                    availability: .init(),
                    actions: .noop
                )
            ))
        #expect(command.title == "Close Pane")
    }

    @Test("Close Pane title stays Close Pane with no selection")
    @MainActor
    func closePaneTitleStaysClosePaneWithNoSelection() throws {
        let store = SessionStore(groups: [])

        let command = try #require(
            PaletteCommandRegistry.command(
                id: KeyboardShortcutCatalog.closePane.id,
                in: PaletteCommandRegistry.commands(
                    sessionStore: store,
                    availability: .init(),
                    actions: .noop
                )
            ))
        #expect(command.title == "Close Pane")
        #expect(!command.isEnabled)
    }

    @Test("Restart Shell command is registered and enabled for a selected session")
    @MainActor
    func restartShellCommandIsRegistered() throws {
        let pane = TerminalPane(title: "only", workingDirectory: "/tmp", executionPlan: .local)
        let session = TerminalSession(
            title: "Solo",
            workingDirectory: "/tmp",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "Code", sessions: [session])],
            selectedSessionID: session.id
        )

        let command = try #require(
            PaletteCommandRegistry.command(
                id: "restartShell",
                in: PaletteCommandRegistry.commands(
                    sessionStore: store,
                    availability: .init(),
                    actions: .noop
                )
            ))
        #expect(command.title == "Restart Shell")
        #expect(command.isEnabled)
    }

    @Test("Recently-closed entries surface as targeted reopen commands")
    @MainActor
    func recentlyClosedEntriesSurfaceAsReopenCommands() throws {
        let doomed = TerminalSession(
            title: "worth keeping",
            workingDirectory: "/tmp",
            isTitleUserEdited: true,
            agentKind: .shell
        )
        let survivor = TerminalSession(title: "stays", workingDirectory: "/tmp", agentKind: .shell)
        let store = SessionStore(groups: [
            SessionGroup(name: "Code", sessions: [doomed, survivor])
        ])
        store.closeSession(id: doomed.id)

        let commands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: .init(),
            actions: .noop
        )

        let reopenCommand = try #require(
            PaletteCommandRegistry.command(
                id: "\(PaletteCommandRegistry.reopenRecentIDPrefix)\(doomed.id.uuidString)",
                in: commands
            ))
        #expect(reopenCommand.title == "Reopen: worth keeping")
        #expect(reopenCommand.isEnabled)
    }

    @Test("Multiple recently-closed entries get distinct reopen command IDs")
    @MainActor
    func multipleEntriesGetDistinctReopenIDs() {
        let first = TerminalSession(
            title: "scratch",
            workingDirectory: "/tmp",
            isTitleUserEdited: true,
            agentKind: .shell
        )
        let second = TerminalSession(
            title: "scratch",
            workingDirectory: "/tmp",
            isTitleUserEdited: true,
            agentKind: .shell
        )
        let survivor = TerminalSession(title: "stays", workingDirectory: "/tmp", agentKind: .shell)
        let store = SessionStore(groups: [
            SessionGroup(name: "Code", sessions: [first, second, survivor])
        ])
        store.closeSession(id: first.id)
        store.closeSession(id: second.id)

        let commands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: .init(),
            actions: .noop
        )
        let reopenIDs = commands.map(\.id)
            .filter { $0.hasPrefix(PaletteCommandRegistry.reopenRecentIDPrefix) }
        #expect(reopenIDs.count == 2)
        #expect(Set(reopenIDs).count == 2)
    }

    @Test("Empty recently-closed buffer yields no targeted reopen commands")
    @MainActor
    func emptyBufferYieldsNoReopenCommands() {
        let store = SessionStore(groups: [])
        let commands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: .init(),
            actions: .noop
        )
        #expect(!commands.contains { $0.id.hasPrefix(PaletteCommandRegistry.reopenRecentIDPrefix) })
    }

    @Test("Disabled commands are filtered from palette results")
    @MainActor
    func disabledCommandsFilteredFromResults() {
        let store = SessionStore(groups: [])
        let commands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: .init(),
            actions: .noop
        )

        let results = PaletteSearch.results(
            groups: store.groups,
            commands: commands,
            rawQuery: "> split"
        )

        let commandIDs = results.flattened.compactMap { result -> String? in
            if case .command(let command) = result {
                return command.commandID
            }
            return nil
        }
        #expect(!commandIDs.contains("splitRight"))
        #expect(!commandIDs.contains("splitDown"))
    }

    @Test("Empty unified query surfaces a Suggested onboarding group")
    @MainActor
    func emptyUnifiedQuerySurfacesSuggestions() {
        let store = SessionStore(groups: [])
        let commands = PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: .init(),
            actions: .noop
        )

        let results = PaletteSearch.results(
            groups: store.groups,
            commands: commands,
            rawQuery: ""
        )

        let suggested = results.groups.first { $0.title == "Suggested" }
        #expect(suggested != nil)

        let suggestedIDs = (suggested?.results ?? []).compactMap { result -> String? in
            if case .command(let command) = result {
                return command.commandID
            }
            return nil
        }
        // Enabled high-value actions are offered...
        #expect(suggestedIDs.contains("newWorkspace"))
        #expect(suggestedIDs.contains("openSettings"))
        // ...while suggestions that are disabled in this state stay hidden.
        #expect(!suggestedIDs.contains("newWorkspaceInCurrentDirectory"))  // no selected session
        #expect(!suggestedIDs.contains("reopenClosedWorkspace"))  // nothing to reopen

        // Bare-query product rule still holds: no implicit selection.
        #expect(results.defaultSelectionIndex == nil)
    }

    @Test @MainActor
    func recentLinkRowsComeOnlyFromFocusedPane() throws {
        var left = TerminalPane(title: "left", workingDirectory: "/tmp", executionPlan: .local)
        var right = TerminalPane(title: "right", workingDirectory: "/tmp", executionPlan: .local)
        left.recentLinks.record("https://left.example/one")
        right.recentLinks.record("https://right.example/two")
        let session = TerminalSession(
            title: "session",
            workingDirectory: "/tmp",
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(left),
                    second: .pane(right)
                )
            ),
            activePaneID: right.id
        )
        let rows = recentLinkRows(in: makeStore(session))
        #expect(rows.count == 1)
        #expect(try #require(rows.first?.subtitle).contains("right.example"))
    }

    @Test @MainActor
    func recentLinkRowsAreNewestFirstAndCapped() {
        var pane = TerminalPane(title: "pane", workingDirectory: "/tmp", executionPlan: .local)
        for index in 0..<25 {
            pane.recentLinks.record("https://example.com/path/\(index)")
        }
        let rows = recentLinkRows(in: makeStore(makeSession(pane)))
        #expect(rows.count == 20)
        #expect(rows.first?.subtitle == "example.com/path/24")
        #expect(rows.last?.subtitle == "example.com/path/5")
    }

    @Test @MainActor
    func noFocusedPaneProducesNoRecentLinkRows() {
        #expect(recentLinkRows(in: SessionStore(groups: [])).isEmpty)
    }

    @Test @MainActor
    func rowRunCapturesExactSessionPaneAndRawValue() throws {
        let raw = "https://user@example.com/private?token=secret#fragment"
        var pane = TerminalPane(title: "pane", workingDirectory: "/tmp", executionPlan: .local)
        pane.recentLinks.record(raw)
        let session = makeSession(pane)
        let store = makeStore(session)
        var received: (String, TerminalSession.ID, TerminalPane.ID)?
        let actions = PaletteAppActions.noop { value, sessionID, paneID in
            received = (value, sessionID, paneID)
        }
        let row = try #require(
            recentLinkRows(in: store, actions: actions).first
        )
        row.run()
        #expect(received?.0 == raw)
        #expect(received?.1 == session.id)
        #expect(received?.2 == pane.id)
    }

    @Test @MainActor
    func rowIDsDoNotContainRawURLOrQueryTokens() throws {
        let raw = "https://example.com/private?token=secret"
        var pane = TerminalPane(title: "pane", workingDirectory: "/tmp", executionPlan: .local)
        pane.recentLinks.record(raw)
        let id = try #require(recentLinkRows(in: makeStore(makeSession(pane))).first?.id)
        #expect(id.hasPrefix(PaletteCommandRegistry.openRecentLinkIDPrefix))
        #expect(!id.contains("example.com"))
        #expect(!id.contains("secret"))
    }

    @Test @MainActor
    func httpPreviewRedactsUserinfoQueryAndFragment() throws {
        var pane = TerminalPane(title: "pane", workingDirectory: "/tmp", executionPlan: .local)
        pane.recentLinks.record("https://user:pass@example.com/account?token=secret#billing")
        let row = try #require(recentLinkRows(in: makeStore(makeSession(pane))).first)
        #expect(row.subtitle == "example.com/account")
        #expect(row.keywords.contains("example.com"))
        #expect(!row.keywords.joined().contains("secret"))
        #expect(!row.keywords.joined().contains("user"))
    }

    @Test @MainActor
    func schemelessPreviewRedactsQuery() throws {
        var pane = TerminalPane(title: "pane", workingDirectory: "/tmp", executionPlan: .local)
        pane.recentLinks.record("example.com/api/login?token=abc123")
        let row = try #require(recentLinkRows(in: makeStore(makeSession(pane))).first)
        let subtitle = try #require(row.subtitle)
        #expect(!subtitle.contains("token=abc123"))
    }

    @Test @MainActor
    func allQueryPreviewUsesGenericFallback() throws {
        var pane = TerminalPane(title: "pane", workingDirectory: "/tmp", executionPlan: .local)
        pane.recentLinks.record("?token=secret")
        let row = try #require(recentLinkRows(in: makeStore(makeSession(pane))).first)
        #expect(row.subtitle == "Detected terminal link")
    }

    @Test @MainActor
    func schemelessPreviewShowsOnlyFinalPathComponent() throws {
        var pane = TerminalPane(title: "pane", workingDirectory: "/tmp", executionPlan: .local)
        pane.recentLinks.record("private-project/readme.md")
        let row = try #require(recentLinkRows(in: makeStore(makeSession(pane))).first)
        #expect(row.subtitle == "readme.md")
        let subtitle = try #require(row.subtitle)
        #expect(!subtitle.contains("private-project"))
    }

    @Test @MainActor
    func topLevelMarkdownLineReferencePreviewShowsFilename() throws {
        var pane = TerminalPane(title: "pane", workingDirectory: "/tmp", executionPlan: .local)
        pane.recentLinks.record("README.md:12")
        let row = try #require(recentLinkRows(in: makeStore(makeSession(pane))).first)
        #expect(row.subtitle == "README.md")
    }

    @Test @MainActor
    func mailtoPreviewDoesNotExposeRecipientOrParameters() throws {
        var pane = TerminalPane(title: "pane", workingDirectory: "/tmp", executionPlan: .local)
        pane.recentLinks.record("mailto:person@example.com?subject=private")
        let row = try #require(recentLinkRows(in: makeStore(makeSession(pane))).first)
        #expect(row.subtitle == "Email link")
        #expect(!row.keywords.joined().contains("person@example.com"))
        #expect(!row.keywords.joined().contains("private"))
    }

    @MainActor
    private func recentLinkRows(
        in store: SessionStore,
        actions: PaletteAppActions = .noop
    ) -> [PaletteCommand] {
        PaletteCommandRegistry.commands(
            sessionStore: store,
            availability: .init(),
            actions: actions
        ).filter { $0.id.hasPrefix(PaletteCommandRegistry.openRecentLinkIDPrefix) }
    }

    private func makeSession(_ pane: TerminalPane) -> TerminalSession {
        TerminalSession(
            title: "session",
            workingDirectory: "/tmp",
            layout: .pane(pane),
            activePaneID: pane.id
        )
    }

    @MainActor
    private func makeStore(_ session: TerminalSession) -> SessionStore {
        SessionStore(
            groups: [SessionGroup(name: "group", sessions: [session])],
            selectedSessionID: session.id
        )
    }
}
