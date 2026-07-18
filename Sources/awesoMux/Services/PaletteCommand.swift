import AwesoMuxConfig
import AwesoMuxCore
import Foundation

@MainActor
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let keywords: [String]
    let shortcut: KeyBinding?
    let isEnabled: Bool
    let run: @MainActor () -> Void
}

extension PaletteCommand {
    /// Pure factory for a user-defined custom command's palette entry, kept
    /// out of `AwesoMuxApp` so id/title/keyword wiring is unit-testable. The
    /// dot id separator matches the `daemonJump.` precedent. Deliberately
    /// never routed through `PaletteQuickRunDetector` — its `isShellyToken`
    /// heuristic silently rejects valid stored commands like `./script.sh`
    /// or `FOO=1 make`.
    static let customCommandIDPrefix = "customCommand."

    /// Inverse of the factory's id encoding, so the app's palette-miss path
    /// can recognize a custom command that was deleted after palette-open and
    /// route it to the store-backed feedback instead of failing silently.
    static func customCommandUUID(fromID id: PaletteCommand.ID) -> UUID? {
        guard id.hasPrefix(customCommandIDPrefix) else {
            return nil
        }
        return UUID(uuidString: String(id.dropFirst(customCommandIDPrefix.count)))
    }

    static func customCommand(
        _ customCommand: CustomCommand,
        run: @escaping @MainActor () -> Void
    ) -> PaletteCommand {
        PaletteCommand(
            id: "\(customCommandIDPrefix)\(customCommand.id.uuidString)",
            title: customCommand.name,
            subtitle: customCommand.command,
            keywords: ["custom", "command", "run", "shortcut", customCommand.command],
            shortcut: nil,
            isEnabled: true,
            run: run
        )
    }
}

@MainActor
struct PaletteAppActions {
    let newWorkspace: @MainActor () -> Void
    let newWorkspaceInCurrentDirectory: @MainActor () -> Void
    let newWorkspaceGroup: @MainActor () -> Void
    let newRemoteWorkspaceGroup: @MainActor () -> Void
    let connectViaSSH: @MainActor () -> Void
    let makeThisWorkspaceManaged: @MainActor () -> Void
    let renameWorkspace: @MainActor () -> Void
    let renamePane: @MainActor () -> Void
    let resetPaneTitle: @MainActor () -> Void
    let closeWorkspace: @MainActor () -> Void
    let clearWorkspace: @MainActor () -> Void
    let reopenClosedWorkspace: @MainActor () -> Void
    let reopenRecent: @MainActor (RecentlyClosedWorkspace) -> Void
    let splitRight: @MainActor () -> Void
    let splitDown: @MainActor () -> Void
    let closePane: @MainActor () -> Void
    let restartShell: @MainActor () -> Void
    let find: @MainActor () -> Void
    let scrollbackDump: @MainActor () -> Void
    let reconnectRemotePane: @MainActor () -> Void
    let growActivePane: @MainActor () -> Void
    let shrinkActivePane: @MainActor () -> Void
    let previousPane: @MainActor () -> Void
    let nextPane: @MainActor () -> Void
    let previousDocumentTab: @MainActor () -> Void
    let nextDocumentTab: @MainActor () -> Void
    let closeDocumentTab: @MainActor () -> Void
    let movePaneUp: @MainActor () -> Void
    let movePaneDown: @MainActor () -> Void
    let movePaneLeft: @MainActor () -> Void
    let movePaneRight: @MainActor () -> Void
    let swapPaneWithNext: @MainActor () -> Void
    let focusPane: @MainActor (Int) -> Void
    let acknowledgeWorkspace: @MainActor () -> Void
    let focusPermissionPrompt: @MainActor () -> Void
    let clearAllNotifications: @MainActor () -> Void
    let toggleFloatingPanel: @MainActor () -> Void
    let togglePopUpTerminal: @MainActor () -> Void
    let toggleCommandPalette: @MainActor () -> Void
    let focusSidebar: @MainActor () -> Void
    let toggleSidebarWidth: @MainActor () -> Void
    let toggleSidebarVisibility: @MainActor () -> Void
    let jumpWorkspace: @MainActor (Int) -> Void
    let previousWorkspace: @MainActor () -> Void
    let nextWorkspace: @MainActor () -> Void
    let togglePinWorkspace: @MainActor () -> Void
    let recenterPalette: @MainActor () -> Void
    let openSettings: @MainActor () -> Void
    let openInIDE: @MainActor () -> Void
    let showKeyboardCheatsheet: @MainActor () -> Void
    let openMarkdownFile: @MainActor () -> Void
    let openSessionManager: @MainActor () -> Void
    let openRecentLink: @MainActor (String, TerminalSession.ID, TerminalPane.ID) -> Void

    static var noop: PaletteAppActions {
        noop()
    }

    static func noop(
        openRecentLink: @escaping @MainActor (String, TerminalSession.ID, TerminalPane.ID) -> Void = {
            _, _, _ in
        }
    ) -> PaletteAppActions {
        let action: @MainActor () -> Void = {}
        let indexedAction: @MainActor (Int) -> Void = { _ in }
        return PaletteAppActions(
            newWorkspace: action,
            newWorkspaceInCurrentDirectory: action,
            newWorkspaceGroup: action,
            newRemoteWorkspaceGroup: action,
            connectViaSSH: action,
            makeThisWorkspaceManaged: action,
            renameWorkspace: action,
            renamePane: action,
            resetPaneTitle: action,
            closeWorkspace: action,
            clearWorkspace: action,
            reopenClosedWorkspace: action,
            reopenRecent: { _ in },
            splitRight: action,
            splitDown: action,
            closePane: action,
            restartShell: action,
            find: action,
            scrollbackDump: action,
            reconnectRemotePane: action,
            growActivePane: action,
            shrinkActivePane: action,
            previousPane: action,
            nextPane: action,
            previousDocumentTab: action,
            nextDocumentTab: action,
            closeDocumentTab: action,
            movePaneUp: action,
            movePaneDown: action,
            movePaneLeft: action,
            movePaneRight: action,
            swapPaneWithNext: action,
            focusPane: indexedAction,
            acknowledgeWorkspace: action,
            focusPermissionPrompt: action,
            clearAllNotifications: action,
            toggleFloatingPanel: action,
            togglePopUpTerminal: action,
            toggleCommandPalette: action,
            focusSidebar: action,
            toggleSidebarWidth: action,
            toggleSidebarVisibility: action,
            jumpWorkspace: indexedAction,
            previousWorkspace: action,
            nextWorkspace: action,
            togglePinWorkspace: action,
            recenterPalette: action,
            openSettings: action,
            openInIDE: action,
            showKeyboardCheatsheet: action,
            openMarkdownFile: action,
            openSessionManager: action,
            openRecentLink: openRecentLink
        )
    }
}

struct PaletteCommandAvailability {
    var isAnySheetPresented = false
    var isOpenInIDEEnabled = true
    var isSidebarHidden = false
    var isSidebarCommandTargetAvailable = true
}

@MainActor
enum PaletteCommandRegistry {
    static let reopenRecentIDPrefix = "reopenRecent."
    static let openRecentLinkIDPrefix = "openRecentLink."

    static func commands(
        sessionStore: SessionStore,
        availability: PaletteCommandAvailability,
        actions: PaletteAppActions,
        keyboard: KeyboardConfig = .defaultValue
    ) -> [PaletteCommand] {
        let selected = sessionStore.selectedSession
        let managedSSHConversionTarget = selected.flatMap {
            sessionStore.managedSSHConversionTarget(
                sessionID: $0.id,
                paneID: $0.activePaneID
            )
        }
        let selectedHasMultiplePanes = selected?.layout.hasMultiplePanes ?? false
        let selectedHasMultipleDocumentTabs =
            (selected?.layout.firstDocumentGroup?.tabs.count ?? 0) > 1
        let selectedHasDocumentTabs = selected?.layout.firstDocumentGroup != nil
        let selectedActivePaneIsUserEdited = selected?.activePane?.isTitleUserEdited ?? false
        // Keyboard/VoiceOver route to the reconnect overlay's button, which is
        // pointer-reachable only (the dead surface swallows Tab). Enabled only
        // while the active pane is showing the enabled `.disconnected` overlay —
        // `.reconnecting` is already in flight (INT-697 fix #3b).
        let selectedActivePaneIsDisconnected: Bool = {
            if case .disconnected = selected?.activePane?.remoteReconnect { return true }
            return false
        }()
        let selectedPaneCount = selected?.layout.paneIDs.count ?? 0
        let workspaceCount = sessionStore.groups.reduce(0) { count, group in
            count + group.sessions.count
        }
        let hasSelectedSession = selected != nil
        let selectedNeedsAcknowledgement =
            selected.map {
                $0.unreadNotificationCount > 0 || $0.needsAcknowledgement
            } ?? false
        let activePaneID = selected?.activePaneID
        let selectedSessionID = selected?.id
        let nextSwapPaneID = selected.flatMap(nextPaneIDForSwap(in:))

        var commands = [
            PaletteCommand(
                id: KeyboardShortcutCatalog.newWorkspace.id,
                title: "New Workspace",
                subtitle: nil,
                keywords: ["create", "tab", "session"],
                shortcut: KeyboardShortcutCatalog.newWorkspace,
                isEnabled: true,
                run: actions.newWorkspace
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.newWorkspaceInCurrentDirectory.id,
                title: "New Workspace in Current Directory",
                subtitle: selected?.workingDirectory,
                keywords: ["create", "cwd", "directory", "session"],
                shortcut: KeyboardShortcutCatalog.newWorkspaceInCurrentDirectory,
                isEnabled: hasSelectedSession,
                run: actions.newWorkspaceInCurrentDirectory
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.newWorkspaceGroup.id,
                title: "New Workspace Group",
                subtitle: nil,
                keywords: ["create", "folder", "project"],
                shortcut: KeyboardShortcutCatalog.newWorkspaceGroup,
                isEnabled: !availability.isAnySheetPresented,
                run: actions.newWorkspaceGroup
            ),
            PaletteCommand(
                id: "newRemoteWorkspaceGroup",
                title: "New Remote Workspace Group",
                subtitle: "Every pane SSHes to a host",
                keywords: ["ssh", "remote", "server", "connect"],
                shortcut: nil,
                isEnabled: !availability.isAnySheetPresented,
                run: actions.newRemoteWorkspaceGroup
            ),
            PaletteCommand(
                id: "connectViaSSH",
                title: "Connect via SSH",
                subtitle: "Create a managed SSH workspace",
                keywords: ["ssh", "remote", "server", "connect"],
                shortcut: nil,
                isEnabled: !availability.isAnySheetPresented,
                run: actions.connectViaSSH
            ),
            PaletteCommand(
                id: "makeThisWorkspaceManaged",
                title: "Make This Workspace Managed…",
                subtitle: managedSSHConversionTarget?.sshDestination,
                keywords: ["ssh", "remote", "managed", "convert", "reconnect"],
                shortcut: nil,
                isEnabled: managedSSHConversionTarget != nil && !availability.isAnySheetPresented,
                run: actions.makeThisWorkspaceManaged
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.renameWorkspace.id,
                title: "Rename Workspace",
                subtitle: selected?.title,
                keywords: ["edit", "title", "name"],
                shortcut: KeyboardShortcutCatalog.renameWorkspace,
                isEnabled: hasSelectedSession && !availability.isAnySheetPresented,
                run: actions.renameWorkspace
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.renamePane.id,
                title: "Rename Pane",
                subtitle: selected?.activePane?.title,
                keywords: ["edit", "pane", "title", "name"],
                shortcut: KeyboardShortcutCatalog.renamePane,
                isEnabled: selectedHasMultiplePanes && !availability.isAnySheetPresented,
                run: actions.renamePane
            ),
            PaletteCommand(
                id: "resetPaneTitle",
                title: "Reset Pane Title",
                subtitle: selected?.activePane?.title,
                keywords: ["pane", "title", "reset", "terminal", "unpin", "clear"],
                shortcut: nil,
                // Only when the active pane carries a user-pinned title — the
                // keyboard/VoiceOver path to un-pin (a11y); inline edit +
                // context menu are pointer-only.
                isEnabled: selectedHasMultiplePanes && selectedActivePaneIsUserEdited,
                run: actions.resetPaneTitle
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.closeWorkspace.id,
                title: "Close Workspace",
                subtitle: selected?.title,
                keywords: ["remove", "session"],
                shortcut: KeyboardShortcutCatalog.closeWorkspace,
                isEnabled: hasSelectedSession,
                run: actions.closeWorkspace
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.clearWorkspace.id,
                title: "Clear Workspace",
                subtitle: selected?.title,
                keywords: ["remove", "permanent", "delete", "forget"],
                shortcut: KeyboardShortcutCatalog.clearWorkspace,
                isEnabled: hasSelectedSession && !availability.isAnySheetPresented,
                run: actions.clearWorkspace
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.reopenClosedWorkspace.id,
                title: "Reopen Closed Workspace",
                subtitle: "Kept for 24 hours",
                keywords: ["restore", "recent", "undo"],
                shortcut: KeyboardShortcutCatalog.reopenClosedWorkspace,
                isEnabled: sessionStore.canReopenClosedWorkspace,
                run: actions.reopenClosedWorkspace
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.splitRight.id,
                title: "Split Right",
                subtitle: nil,
                keywords: ["divide", "vertical", "pane"],
                shortcut: KeyboardShortcutCatalog.splitRight,
                isEnabled: hasSelectedSession,
                run: actions.splitRight
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.splitDown.id,
                title: "Split Down",
                subtitle: nil,
                keywords: ["divide", "horizontal", "pane"],
                shortcut: KeyboardShortcutCatalog.splitDown,
                isEnabled: hasSelectedSession,
                run: actions.splitDown
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.closePane.id,
                // actions.closePane routes single-pane sessions through
                // closeWorkspace(_:) (mirrors closeActivePane()'s App-menu
                // conditional), so the palette title has to match.
                // ponytail: like every row here, the title snapshots at
                // palette-open (see the daemon-row snapshot comment in
                // AwesoMuxApp); a layout change while the palette floats can
                // stale it until the next summon. Live retitling needs
                // render-time recompute in PalettePresenter — do that if the
                // window bites for real.
                title: (selected?.layout.isSinglePane ?? false) ? "Close Workspace" : "Close Pane",
                subtitle: nil,
                keywords: ["remove", "terminal"],
                shortcut: KeyboardShortcutCatalog.closePane,
                isEnabled: hasSelectedSession,
                run: actions.closePane
            ),
            PaletteCommand(
                id: "restartShell",
                title: "Restart Shell",
                subtitle: selected?.activePane?.title,
                // Explicit command replacement for the old single-pane ⌘W
                // silent recycle (ADR-0002 amendment) — recycles the active
                // pane's shell in place. Not gated on isSinglePane: recycling
                // the active pane works the same for a multi-pane session.
                keywords: ["restart", "shell", "recycle", "fresh", "reset"],
                shortcut: nil,
                isEnabled: hasSelectedSession,
                run: actions.restartShell
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.find.id,
                title: "Find in Pane",
                subtitle: selected?.activePane?.title,
                keywords: ["search", "terminal", "scrollback"],
                shortcut: KeyboardShortcutCatalog.find,
                isEnabled: hasSelectedSession && !availability.isAnySheetPresented,
                run: actions.find
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.scrollbackDump.id,
                title: "Show Scrollback",
                subtitle: selected?.activePane?.title,
                keywords: ["search", "terminal", "copy", "dump"],
                shortcut: KeyboardShortcutCatalog.scrollbackDump,
                isEnabled: hasSelectedSession && !availability.isAnySheetPresented,
                run: actions.scrollbackDump
            ),
            PaletteCommand(
                id: "reconnectRemotePane",
                title: "Reconnect Remote Pane",
                subtitle: selected?.activePane?.title,
                keywords: ["remote", "ssh", "reconnect", "disconnected", "retry"],
                shortcut: nil,
                isEnabled: selectedActivePaneIsDisconnected,
                run: actions.reconnectRemotePane
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.growActivePane.id,
                title: "Grow Active Pane",
                subtitle: nil,
                keywords: ["resize", "larger"],
                shortcut: KeyboardShortcutCatalog.growActivePane,
                isEnabled: selectedHasMultiplePanes,
                run: actions.growActivePane
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.shrinkActivePane.id,
                title: "Shrink Active Pane",
                subtitle: nil,
                keywords: ["resize", "smaller"],
                shortcut: KeyboardShortcutCatalog.shrinkActivePane,
                isEnabled: selectedHasMultiplePanes,
                run: actions.shrinkActivePane
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.previousPane.id,
                title: "Previous Pane",
                subtitle: nil,
                keywords: ["focus", "terminal"],
                shortcut: KeyboardShortcutCatalog.previousPane,
                isEnabled: selectedHasMultiplePanes,
                run: actions.previousPane
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.nextPane.id,
                title: "Next Pane",
                subtitle: nil,
                keywords: ["focus", "terminal"],
                shortcut: KeyboardShortcutCatalog.nextPane,
                isEnabled: selectedHasMultiplePanes,
                run: actions.nextPane
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.previousDocumentTab.id,
                title: "Previous Document Tab",
                subtitle: nil,
                keywords: ["document", "markdown", "tab", "switch"],
                shortcut: KeyboardShortcutCatalog.previousDocumentTab,
                isEnabled: selectedHasMultipleDocumentTabs,
                run: actions.previousDocumentTab
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.nextDocumentTab.id,
                title: "Next Document Tab",
                subtitle: nil,
                keywords: ["document", "markdown", "tab", "switch"],
                shortcut: KeyboardShortcutCatalog.nextDocumentTab,
                isEnabled: selectedHasMultipleDocumentTabs,
                run: actions.nextDocumentTab
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.closeDocumentTab.id,
                title: "Close Document Tab",
                subtitle: selected?.layout.firstDocumentGroup?.selectedTab?.title,
                keywords: ["document", "markdown", "tab"],
                shortcut: KeyboardShortcutCatalog.closeDocumentTab,
                isEnabled: selectedHasDocumentTabs,
                run: actions.closeDocumentTab
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.movePaneUp.id,
                title: "Move Pane Up",
                subtitle: nil,
                keywords: ["rearrange", "terminal"],
                shortcut: KeyboardShortcutCatalog.movePaneUp,
                isEnabled: canMoveActivePane(
                    id: activePaneID,
                    toWorkspaceEdge: .up,
                    in: selectedSessionID,
                    sessionStore: sessionStore
                ),
                run: actions.movePaneUp
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.movePaneDown.id,
                title: "Move Pane Down",
                subtitle: nil,
                keywords: ["rearrange", "terminal"],
                shortcut: KeyboardShortcutCatalog.movePaneDown,
                isEnabled: canMoveActivePane(
                    id: activePaneID,
                    toWorkspaceEdge: .down,
                    in: selectedSessionID,
                    sessionStore: sessionStore
                ),
                run: actions.movePaneDown
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.movePaneLeft.id,
                title: "Move Pane Left",
                subtitle: nil,
                keywords: ["rearrange", "terminal"],
                shortcut: KeyboardShortcutCatalog.movePaneLeft,
                isEnabled: canMoveActivePane(
                    id: activePaneID,
                    toWorkspaceEdge: .left,
                    in: selectedSessionID,
                    sessionStore: sessionStore
                ),
                run: actions.movePaneLeft
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.movePaneRight.id,
                title: "Move Pane Right",
                subtitle: nil,
                keywords: ["rearrange", "terminal"],
                shortcut: KeyboardShortcutCatalog.movePaneRight,
                isEnabled: canMoveActivePane(
                    id: activePaneID,
                    toWorkspaceEdge: .right,
                    in: selectedSessionID,
                    sessionStore: sessionStore
                ),
                run: actions.movePaneRight
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.swapPaneWithNext.id,
                title: "Swap Pane With Next",
                subtitle: nil,
                keywords: ["rearrange", "terminal"],
                shortcut: KeyboardShortcutCatalog.swapPaneWithNext,
                isEnabled: canSwapActivePane(
                    id: activePaneID,
                    with: nextSwapPaneID,
                    in: selectedSessionID,
                    sessionStore: sessionStore
                ),
                run: actions.swapPaneWithNext
            ),
        ]

        commands.append(
            contentsOf: KeyboardShortcutCatalog.focusPaneBindings.enumerated().map { offset, binding in
                let paneIndex = offset + 1
                return PaletteCommand(
                    id: binding.id,
                    title: binding.action,
                    subtitle: nil,
                    keywords: ["pane", "terminal", "focus", "\(paneIndex)"],
                    shortcut: binding,
                    isEnabled: selectedPaneCount > 1 && paneIndex <= selectedPaneCount,
                    run: { actions.focusPane(paneIndex) }
                )
            })

        commands.append(contentsOf: [
            PaletteCommand(
                id: KeyboardShortcutCatalog.acknowledgeWorkspace.id,
                title: "Acknowledge Workspace",
                subtitle: nil,
                keywords: ["mark", "read", "clear", "notification"],
                shortcut: KeyboardShortcutCatalog.acknowledgeWorkspace,
                isEnabled: selectedNeedsAcknowledgement,
                run: actions.acknowledgeWorkspace
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.focusPermissionPrompt.id,
                title: "Focus Permission Prompt",
                subtitle: selected?.activePane?.title,
                keywords: ["permission", "allow", "deny", "remote", "agent", "prompt", "authorize"],
                shortcut: KeyboardShortcutCatalog.focusPermissionPrompt,
                // Always offered when a session is selected: the registry can't
                // see per-attach coordinators, so the command no-ops when no
                // prompt is active rather than gating on prompt presence here.
                isEnabled: hasSelectedSession,
                run: actions.focusPermissionPrompt
            ),
            PaletteCommand(
                id: "clearAllNotifications",
                title: "Clear All Notifications",
                subtitle: nil,
                keywords: ["acknowledge", "mark", "read"],
                shortcut: nil,
                isEnabled: sessionStore.unreadNotificationTotal > 0,
                run: actions.clearAllNotifications
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.toggleFloatingPanel.id,
                title: "Toggle Floating Panel",
                subtitle: nil,
                keywords: ["shell", "quick", "terminal"],
                shortcut: KeyboardShortcutCatalog.toggleFloatingPanel,
                isEnabled: !availability.isAnySheetPresented,
                run: actions.toggleFloatingPanel
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.togglePopUpTerminal.id,
                title: "Toggle Terminal Companion",
                subtitle: "Terminal companion across workspaces",
                keywords: ["shell", "global", "terminal", "popup", "pocket"],
                shortcut: KeyboardShortcutCatalog.togglePopUpTerminal,
                isEnabled: !availability.isAnySheetPresented,
                run: actions.togglePopUpTerminal
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.toggleCommandPalette.id,
                title: "Command Palette",
                subtitle: nil,
                keywords: ["search", "actions", "commands"],
                shortcut: KeyboardShortcutCatalog.toggleCommandPalette,
                isEnabled: !availability.isAnySheetPresented,
                run: actions.toggleCommandPalette
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.focusSidebar.id,
                title: "Focus Sidebar",
                subtitle: nil,
                keywords: ["search", "workspaces", "sessions"],
                shortcut: KeyboardShortcutCatalog.focusSidebar,
                isEnabled: !availability.isAnySheetPresented
                    && availability.isSidebarCommandTargetAvailable,
                run: actions.focusSidebar
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.toggleSidebarWidth.id,
                title: "Collapse/Expand Sidebar",
                subtitle: nil,
                keywords: ["toggle", "rail", "workspace list"],
                shortcut: KeyboardShortcutCatalog.toggleSidebarWidth,
                isEnabled: !availability.isAnySheetPresented
                    && availability.isSidebarCommandTargetAvailable,
                run: actions.toggleSidebarWidth
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.toggleSidebarVisibility.id,
                title: SidebarVisibilityActionTitle.resolve(isHidden: availability.isSidebarHidden),
                subtitle: nil,
                keywords: ["toggle", "hide", "show", "workspace list"],
                shortcut: KeyboardShortcutCatalog.toggleSidebarVisibility,
                isEnabled: !availability.isAnySheetPresented
                    && availability.isSidebarCommandTargetAvailable,
                run: actions.toggleSidebarVisibility
            ),
        ])

        commands.append(
            contentsOf: KeyboardShortcutCatalog.jumpWorkspaces.enumerated().map { offset, binding in
                let workspaceIndex = offset + 1
                return PaletteCommand(
                    id: binding.id,
                    title: binding.action,
                    subtitle: nil,
                    keywords: ["workspace", "session", "jump", "\(workspaceIndex)"],
                    shortcut: binding,
                    isEnabled: !availability.isAnySheetPresented && offset < workspaceCount,
                    run: { actions.jumpWorkspace(offset) }
                )
            })

        commands.append(contentsOf: [
            PaletteCommand(
                id: KeyboardShortcutCatalog.previousWorkspace.id,
                title: "Previous Workspace",
                subtitle: nil,
                keywords: ["session", "back"],
                shortcut: KeyboardShortcutCatalog.previousWorkspace,
                isEnabled: workspaceCount > 1,
                run: actions.previousWorkspace
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.nextWorkspace.id,
                title: "Next Workspace",
                subtitle: nil,
                keywords: ["session", "forward"],
                shortcut: KeyboardShortcutCatalog.nextWorkspace,
                isEnabled: workspaceCount > 1,
                run: actions.nextWorkspace
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.togglePinWorkspace.id,
                title: selected.map { sessionStore.isPinned($0.id) } == true
                    ? "Unpin Workspace"
                    : "Pin Workspace",
                subtitle: selected?.title,
                keywords: ["pin", "unpin", "favorite", "sidebar"],
                shortcut: KeyboardShortcutCatalog.togglePinWorkspace,
                isEnabled: hasSelectedSession && !availability.isAnySheetPresented,
                run: actions.togglePinWorkspace
            ),
            PaletteCommand(
                id: "recenterPalette",
                title: "Reset Palette Position",
                subtitle: nil,
                keywords: ["center", "recenter", "move", "position", "palette"],
                shortcut: nil,
                isEnabled: true,
                run: actions.recenterPalette
            ),
            PaletteCommand(
                id: "openSettings",
                title: "Open Settings",
                subtitle: nil,
                keywords: ["preferences", "configuration"],
                shortcut: nil,
                isEnabled: true,
                run: actions.openSettings
            ),
            PaletteCommand(
                id: "openInIDE",
                title: "Open in IDE…",
                subtitle: selected?.activePane?.title,
                keywords: ["open", "ide", "editor", "project", "worktree"],
                shortcut: nil,
                isEnabled: hasSelectedSession
                    && !availability.isAnySheetPresented
                    && availability.isOpenInIDEEnabled
                    && selected.map(IDEOpenTarget.isEligible(session:)) == true,
                run: actions.openInIDE
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.showKeyboardCheatsheet.id,
                title: "Keyboard Shortcuts",
                subtitle: nil,
                keywords: ["cheatsheet", "help", "keys"],
                shortcut: KeyboardShortcutCatalog.showKeyboardCheatsheet,
                isEnabled: !availability.isAnySheetPresented,
                run: actions.showKeyboardCheatsheet
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.openMarkdownFile.id,
                title: "Open Markdown File…",
                subtitle: nil,
                keywords: ["document", "markdown", "viewer", "open", "pane"],
                shortcut: KeyboardShortcutCatalog.openMarkdownFile,
                isEnabled: hasSelectedSession,
                run: actions.openMarkdownFile
            ),
            PaletteCommand(
                id: KeyboardShortcutCatalog.sessionManager.id,
                title: "Open Session Manager",
                subtitle: nil,
                keywords: ["background", "sessions", "daemons", "bridges", "detached"],
                shortcut: KeyboardShortcutCatalog.sessionManager,
                isEnabled: !availability.isAnySheetPresented,
                run: actions.openSessionManager
            ),
        ])

        // One targeted-reopen command per recently-closed entry (INT-282) —
        // the palette twin of the Dock "Recent Workspaces" submenu. Dot id
        // matches the `daemonJump.` / `customCommand.` precedent; sessionID
        // is unique per close (see RecentlyClosedWorkspaceReducer.drain).
        commands.append(
            contentsOf: sessionStore.recentWorkspaces(
                limit: SessionStore.maxRecentlyClosed
            ).map { entry in
                PaletteCommand(
                    id: "\(reopenRecentIDPrefix)\(entry.sessionID.uuidString)",
                    title: "Reopen: \(DockRecentWorkspaceMenu.displayTitle(for: entry))",
                    // Relative close time so same-titled entries (two "scratch"
                    // workspaces) stay distinguishable in the list.
                    subtitle: "Closed \(entry.closedAt.formatted(.relative(presentation: .named)))",
                    keywords: ["restore", "recent", "reopen", "closed"],
                    shortcut: nil,
                    isEnabled: true,
                    run: { actions.reopenRecent(entry) }
                )
            })

        if let selected, let activePane = selected.activePane {
            let sessionID = selected.id
            let paneID = activePane.id
            commands.append(
                contentsOf: activePane.recentLinks.values.map { value in
                    let presentation = recentLinkPresentation(for: value)
                    return PaletteCommand(
                        id: "\(openRecentLinkIDPrefix)\(stableDigest(of: value, paneID: paneID))",
                        title: String(
                            localized: "Open Recent Link",
                            comment: "Command palette action for opening a link detected in a terminal pane"
                        ),
                        subtitle: presentation.preview,
                        keywords: ["link", "url", "open", "recent"] + presentation.keywords,
                        shortcut: nil,
                        isEnabled: true,
                        run: { actions.openRecentLink(value, sessionID, paneID) }
                    )
                })
        }

        return commands.map { command in
            guard let shortcut = command.shortcut else { return command }
            return PaletteCommand(
                id: command.id,
                title: command.title,
                subtitle: command.subtitle,
                keywords: command.keywords,
                shortcut: KeyboardShortcutCatalog.resolved(shortcut, keyboard: keyboard),
                isEnabled: command.isEnabled,
                run: command.run
            )
        }
    }

    static func command(id: PaletteCommand.ID, in commands: [PaletteCommand]) -> PaletteCommand? {
        commands.first { $0.id == id }
    }

    private static func stableDigest(of value: String, paneID: TerminalPane.ID) -> String {
        var digest: UInt64 = 14_695_981_039_346_656_037
        for byte in paneID.uuidString.utf8 {
            digest = (digest ^ UInt64(byte)) &* 1_099_511_628_211
        }
        digest = (digest ^ 0xFF) &* 1_099_511_628_211
        for byte in value.utf8 {
            digest = (digest ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(digest, radix: 16)
    }

    private static func recentLinkPresentation(for value: String) -> (preview: String, keywords: [String]) {
        let fallback = String(
            localized: "Detected terminal link",
            comment: "Privacy-preserving preview for an unrecognized terminal link"
        )
        if let documentPath = MarkdownLinkIntercept.relativeDocumentCandidatePath(value) {
            let trailingPath = documentPath.split(separator: "/", omittingEmptySubsequences: true)
                .suffix(1)
                .joined(separator: "/")
            return (boundedSafePreview(trailingPath), [])
        }
        guard let components = URLComponents(string: value) else {
            return (boundedSafePreview(fallback), [])
        }

        switch components.scheme?.lowercased() {
        case "http", "https":
            guard let host = components.host, !host.isEmpty else {
                return (boundedSafePreview(fallback), [])
            }
            let safeHost = boundedSafePreview(host)
            return (
                boundedSafePreview(host + components.percentEncodedPath),
                safeHost.isEmpty ? [] : [safeHost]
            )
        case "mailto":
            return (
                boundedSafePreview(
                    String(
                        localized: "Email link",
                        comment: "Privacy-preserving preview for a detected email link"
                    )),
                []
            )
        case nil:
            let redactedValue = value.prefix { $0 != "?" && $0 != "#" }
            let pathComponents = redactedValue.split(separator: "/", omittingEmptySubsequences: true)
            let trailingPath = pathComponents.suffix(1).joined(separator: "/")
            return (boundedSafePreview(trailingPath.isEmpty ? String(redactedValue) : trailingPath), [])
        default:
            return (boundedSafePreview(fallback), [])
        }
    }

    private static func boundedSafePreview(_ value: String) -> String {
        let safeScalars = value.unicodeScalars.filter {
            !GhosttyRuntime.isUnsafeAlertBodyScalar($0)
        }
        return String(String.UnicodeScalarView(safeScalars).prefix(72))
    }

    private static func canMoveActivePane(
        id paneID: TerminalPane.ID?,
        toWorkspaceEdge edge: PaneMoveEdge,
        in sessionID: TerminalSession.ID?,
        sessionStore: SessionStore
    ) -> Bool {
        guard let paneID, let sessionID else {
            return false
        }
        return sessionStore.canMovePane(
            id: paneID,
            toWorkspaceEdge: edge,
            in: sessionID
        )
    }

    private static func canSwapActivePane(
        id paneID: TerminalPane.ID?,
        with nextPaneID: TerminalPane.ID?,
        in sessionID: TerminalSession.ID?,
        sessionStore: SessionStore
    ) -> Bool {
        guard let paneID, let nextPaneID, let sessionID else {
            return false
        }
        return sessionStore.canSwapPanes(
            firstID: paneID,
            secondID: nextPaneID,
            in: sessionID
        )
    }

    private static func nextPaneIDForSwap(in session: TerminalSession) -> TerminalPane.ID? {
        let paneIDs = session.layout.paneIDs
        guard paneIDs.count > 1,
            let activeIndex = paneIDs.firstIndex(of: session.activePaneID)
        else {
            return nil
        }
        return paneIDs[(activeIndex + 1) % paneIDs.count]
    }
}
