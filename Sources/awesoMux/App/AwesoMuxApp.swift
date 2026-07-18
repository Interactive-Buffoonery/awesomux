import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import os
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import UserNotifications

/// Must run before `GhosttyRuntime.initialize()` (which snapshots the
/// process environment into libghostty's app config) and before any other
/// reader of `getenv` for these keys. `unsetenv`/`setenv` are not thread-safe
/// on macOS; this call site relies on running pre-runtime in `AwesoMuxApp.init`
/// (the first statement, before any background work has started). Keep it first.
private func sanitizeInheritedTerminalContextFromProcessEnvironment() {
    for key in TerminalAppearancePreferences.inheritedTerminalContextKeys {
        unsetenv(key)
    }
    for key in AgentRuntimeEnvironmentKey.paneScopedKeys {
        unsetenv(key)
    }
    // Compact-terminal spawn markers describe the parent terminal's surface,
    // not this instance's fresh panes — same rationale as the pane-scoped keys
    // above. Without this, launching awesoMux from a compact terminal leaks the
    // marker into every regular pane's shell.
    // Deliberately NOT in `inheritedTerminalContextKeys`: that list is also
    // stripped from the per-surface merge dict, which would delete the
    // deliberately-injected marker and break the feature.
    unsetenv(FloatingPanelStoreFactory.spawnEnvironmentKey)
    unsetenv(CompactTerminalKind.spawnEnvironmentKey)
    // Strip the GHOSTTY_*/CMUX_* families too. When awesoMux is launched from
    // inside another ghostty-based terminal (Ghostty, cmux, or awesoMux
    // itself), the child process inherits GHOSTTY_RESOURCES_DIR / GHOSTTY_BIN_DIR
    // / GHOSTTY_SHELL_FEATURES pointing at the PARENT's bundle. In release
    // builds libghostty's resources-dir detection trusts GHOSTTY_RESOURCES_DIR
    // first (see vendor/ghostty os/resourcesdir.zig), so it would load the
    // parent's shell integration and ours would never install — no OSC 133
    // prompt markers, so `cursorIsAtPrompt` is always false and the quit-confirm
    // gate fires on every shell. Stripping these forces libghostty to
    // re-detect our own bundle via selfExePath. Same rationale as the
    // tmux/zellij markers above: they describe the parent terminal, not the
    // fresh pane.
    // ZMX_*/AMX_* describe the PARENT's daemon world when we're launched from
    // inside a bridge pane: ZMX_DIR points at the parent profile's socket dir
    // and AMX_STATUS_TOKEN is the parent pane's status-forgery guard. Our own
    // bridge pins ZMX_DIR/ZMX_DIR_MODE explicitly per attach, so nothing here
    // relies on the inherited values — but every non-bridge pane shell we spawn
    // would, letting a "dev" pane's `amx list`/`kill` silently operate on the
    // production daemon set. AWESOMUX_PROFILE is launcher/helper-script input
    // (amx-reap.sh); the app resolves its profile from the bundle id and must
    // not forward a stale inherited value into pane shells.
    for key in ProcessInfo.processInfo.environment.keys
    where key.hasPrefix("GHOSTTY_") || key.hasPrefix("CMUX_")
        || key.hasPrefix("ZMX_") || key.hasPrefix("AMX_")
        || key == "AWESOMUX_PROFILE"
    {
        unsetenv(key)
    }

    // Then assert our OWN resources dir authoritatively. libghostty's release
    // resources-dir lookup is env-var-first, then selfExePath detection; by
    // setting GHOSTTY_RESOURCES_DIR to our bundle we don't merely strip the
    // impostor, we pin libghostty to our shell integration regardless of how
    // we were launched. Guarded by an existence check so a non-bundle launch
    // (e.g. `swift run`) falls back to detection instead of forcing a bad path.
    if let resourcePath = Bundle.main.resourcePath {
        let ownGhosttyResources = resourcePath + "/ghostty"
        // Pin only if our bundle actually carries the shell integration. A bare
        // `ghostty` dir without `shell-integration` would reintroduce the
        // no-OSC-133 symptom with no fallback; if it's absent (e.g. `swift run`,
        // unstaged dev binary) leave GHOSTTY_RESOURCES_DIR unset so libghostty's
        // selfExePath detection takes over.
        if FileManager.default.fileExists(atPath: ownGhosttyResources + "/shell-integration") {
            setenv("GHOSTTY_RESOURCES_DIR", ownGhosttyResources, 1)
        }
    }
}

@main
struct AwesoMuxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sessionStore: SessionStore
    @State private var ghosttyRuntime: GhosttyRuntime
    @State private var workspaceEditRequest: WorkspaceEditRequest?
    @State private var paneEditRequest: PaneEditRequest?
    @State private var workspaceGroupCreateRequest: WorkspaceGroupCreateRequest?
    @State private var remoteWorkspaceGroupCreateRequest: RemoteWorkspaceGroupCreateRequest?
    @State private var sshWorkspaceConnectRequest: SSHWorkspaceConnectRequest?
    @State private var workspaceGroupRenameRequest: WorkspaceGroupRenameRequest?
    @State private var quickSettingsRequest: QuickSettingsRequest?
    @State private var recoveryWarning: SessionPersistence.SessionRecoveryWarning?
    @State private var didPresentRecoveryWarning = false
    @State private var floatingPanelController = TerminalPanelController(mode: .floating)
    @State private var popUpTerminalController = TerminalPanelController(mode: .companion)
    @State private var commandPaletteController = CommandPaletteController()
    @State private var keyboardCheatsheetController = KeyboardCheatsheetController()
    @State private var sessionManagerController = SessionManagerController()
    @State private var sessionManagerModel: SessionManagerModel
    @State private var worktreeManagerController = WorktreeManagerController()
    @State private var worktreeManagerModel: WorktreeManagerModel?
    @State private var diagnosticsModel: DiagnosticsModel
    /// The SwiftUI-native window action, captured from the window's environment
    /// so App-level wiring can open scenes without AppKit selectors.
    @State private var openWindowAction: OpenWindowAction?
    @State private var terminalAppearancePreferencesCache: TerminalAppearancePreferencesCache
    @State private var appSettingsStore: AppSettingsStore
    @State private var customCommandStore = CustomCommandStore()
    @State private var isCloseConfirmAlertPresented = false
    @State private var sidebarPresentationCommandMailbox = SidebarPresentationCommandMailbox()
    @State private var sidebarWidthToggleRequestID: UUID?
    @State private var isSidebarPersistentlyHidden = SidebarPresentationPreferenceStore().isHidden()
    @State private var sidebarCommandTargetAvailability = SidebarCommandTargetAvailability()
    @State private var quickRunToast: QuickRunToast?
    @State private var documentTabActions = DocumentComposeTabActionHandler()

    private static let logger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "sidebar"
    )

    private var preferredScheme: ColorScheme? {
        appSettingsStore.appearance.value.theme.colorScheme
    }

    private var keyboardConfig: KeyboardConfig {
        appSettingsStore.keyboard.value
    }

    private func shortcut(_ binding: KeyBinding) -> KeyBinding {
        KeyboardShortcutCatalog.resolved(binding, keyboard: keyboardConfig)
    }

    private func shortcuts(_ bindings: [KeyBinding]) -> [KeyBinding] {
        KeyboardShortcutCatalog.resolved(bindings, keyboard: keyboardConfig)
    }

    init() {
        _ = AwesoMuxApplication.shared
        DesignSystemFonts.registerBundledFonts()

        // Ghostty snapshots the process environment when it builds each PTY's
        // base env. Drop stale launcher-only terminal context once, before the
        // runtime starts, instead of mutating process env around every surface.
        sanitizeInheritedTerminalContextFromProcessEnvironment()
        // Must run before SessionPersistence.load() and before any
        // AppDelegate lifecycle callback fires (applicationWillFinishLaunching,
        // applicationDidFinishLaunching, .onAppear). Non-`@AppStorage`
        // consumers reading `UserDefaults.standard.bool(forKey:)` directly
        // otherwise see the type's zero value (false / "" / 0) instead of
        // the documented `SettingsDefault` — see INT-159.
        SettingsDefault.registerInitialValues()
        let runtimeProfile = AppRuntimeProfile.current
        let diagnosticEvents = LocalDiagnosticEventRecorder()
        let mapDiagnosticTrigger: (AppSettingsDiagnosticTrigger) -> LocalDiagnosticConfigurationTrigger = {
            $0 == .manual ? .manual : .watcher
        }
        let appSettingsStore = AppSettingsStore(
            fileStore: ConfigFileStore(
                pathResolver: ConfigPathResolver(
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                    configDirectoryName: runtimeProfile.configDirectoryName
                )
            ),
            diagnosticEventHandler: { event in
                switch event {
                case let .reloadSucceeded(trigger):
                    diagnosticEvents.record(
                        .configurationReloaded(
                            trigger: mapDiagnosticTrigger(trigger)
                        ))
                case let .reloadRejected(trigger):
                    diagnosticEvents.record(
                        .configurationRejected(
                            trigger: mapDiagnosticTrigger(trigger)
                        ))
                case .resetAfterDeletion:
                    diagnosticEvents.record(.configurationReset)
                case .resetAfterDeletionRejected:
                    diagnosticEvents.record(.configurationResetRejected)
                }
            }
        )
        appSettingsStore.bootstrap()
        appSettingsStore.startWatching()
        let terminalAppearancePreferencesCache = TerminalAppearancePreferencesCache()
        let initialAppearance = appSettingsStore.appearance.value
        AwUIFontRuntime.current = AwUIFontResolver.resolvedForSystem(
            rawFamily: initialAppearance.uiFont
        )
        let persistedTerminalAppearance = TerminalAppearancePreferences(
            appearance: initialAppearance,
            effectiveTheme: terminalEffectiveTheme(for: initialAppearance)
        )
        terminalAppearancePreferencesCache.update(persistedTerminalAppearance)
        let loadResult: SessionPersistence.LoadResult
        if appSettingsStore.general.value.restoreWorkspaces {
            loadResult = SessionPersistence.load()
        } else {
            let store = SessionStore()
            SessionPersistence.scheduleRemoteMarkdownSnapshotPrune(keeping: store)
            loadResult = SessionPersistence.LoadResult(store: store, recoveryWarning: nil)
        }
        _appSettingsStore = State(initialValue: appSettingsStore)
        _sessionStore = State(initialValue: loadResult.store)
        if let warning = loadResult.recoveryWarning {
            switch warning.kind {
            case .archivedSnapshot:
                diagnosticEvents.record(.restoreArchived)
            case .sanitizedRestore:
                diagnosticEvents.record(.restoreSanitized)
            }
        }
        let diagnosticsModel = DiagnosticsModel(
            sessionStore: loadResult.store,
            eventRecorder: diagnosticEvents
        )
        _diagnosticsModel = State(initialValue: diagnosticsModel)
        _ghosttyRuntime = State(
            initialValue: GhosttyRuntime(
                terminalAppearanceProvider: {
                    let appearance = appSettingsStore.appearance.value
                    return terminalAppearancePreferencesCache.preferences(
                        for: appearance,
                        fallbackEffectiveTheme: terminalEffectiveTheme(for: appearance)
                    )
                },
                initialClipboardWritePolicy: appSettingsStore.terminal.value.clipboardWritePolicy,
                initialConfirmClipboardRead: appSettingsStore.terminal.value.confirmClipboardRead,
                initialCopyOnSelect: appSettingsStore.terminal.value.copyOnSelect,
                initialCommandBridgeEnabled: appSettingsStore.terminal.value.commandBridgeEnabled,
                diagnosticEventHandler: { diagnosticEvents.record($0) }
            ))
        _terminalAppearancePreferencesCache = State(initialValue: terminalAppearancePreferencesCache)
        _recoveryWarning = State(initialValue: loadResult.recoveryWarning)
        _sessionManagerModel = State(
            initialValue: SessionManagerModel(
                store: loadResult.store,
                settings: appSettingsStore
            ))
    }

    var body: some Scene {
        Window("awesoMux", id: AwesoMuxSceneID.primary) {
            // Any future animation in this root view should check
            // `@Environment(\.accessibilityReduceMotion)` before animating.
            ContentView(
                sessionStore: sessionStore,
                ghosttyRuntime: ghosttyRuntime,
                floatingPanelController: floatingPanelController,
                onCloseWorkspace: closeWorkspace,
                onClearWorkspace: clearWorkspace,
                onCloseWorkspaceGroup: closeWorkspaceGroup,
                onRenameWorkspace: requestRenameWorkspace,
                onRenameWorkspaceGroup: requestRenameWorkspaceGroup,
                onNewWorkspaceGroup: requestNewWorkspaceGroup,
                onConnectViaSSH: { group in requestConnectViaSSH(group) },
                canMakeWorkspaceManaged: canMakeWorkspaceManaged,
                onMakeWorkspaceManaged: { requestManagedSSHWorkspaceConversion($0) },
                onManagedSSHWorkspaceOffer: requestManagedSSHWorkspaceOffer,
                onReopenClosedWorkspace: reopenMostRecentlyClosedWorkspace,
                hasRecoveryWarning: recoveryWarning != nil,
                onOpenQuickSettings: requestQuickSettings,
                onToggleCommandPalette: toggleCommandPalette,
                onOpenSelectedWorkspaceInIDE: { openSelectedWorkspaceInIDE() },
                onOpenSelectedWorkspaceInIDEWithApp: open,
                onTerminalFooterHeightChange: { height in
                    popUpTerminalController.updateBottomInset(height)
                },
                onFocusAgentPane: { sessionID, paneID in
                    // Mirror the peek card's pane jump (ContentView.wirePeekSelection):
                    // guard the ghost-click (roster rows are render-time snapshots), then
                    // setActivePane BEFORE ack/focus — requestTerminalFocus alone moves
                    // first responder but not the model's active pane, which strands the
                    // path bar / per-pane ack on the wrong pane (review finding).
                    guard let session = sessionStore.session(id: sessionID),
                        let paneIndex = session.layout.paneIDs.firstIndex(of: paneID)
                    else {
                        // Roster rows are render-time snapshots; the pane can vanish
                        // between build and click. IDs only — privacy-safe.
                        Self.logger.debug(
                            "agent panel jump dropped stale row sessionID=\(sessionID, privacy: .public) paneID=\(paneID, privacy: .public)"
                        )
                        return
                    }
                    sessionStore.selectedSessionID = sessionID
                    appDelegate.surfacePrimaryWindow()
                    sessionStore.setActivePane(id: paneID, in: sessionID)
                    // Explicit gesture → immediate ack, same as the peek card (ADR-0003).
                    sessionStore.acknowledgeSession(id: sessionID)
                    requestTerminalFocus(sessionID: sessionID, paneID: paneID)
                    announcePaneFocused(index: paneIndex + 1)
                },
                onFocusActiveTerminal: focusActiveTerminal,
                sidebarPresentationCommandMailbox: sidebarPresentationCommandMailbox,
                sidebarWidthToggleRequestID: sidebarWidthToggleRequestID,
                onSidebarPresentationCommandAcknowledged: { commandID in
                    sidebarPresentationCommandMailbox.acknowledge(id: commandID)
                },
                onSidebarPersistentVisibilityChange: { hidden in
                    isSidebarPersistentlyHidden = hidden
                }
            )
            .frame(
                minWidth: ContentView.minimumWindowWidth,
                minHeight: ContentView.minimumWindowHeight
            )
            .sheet(item: $workspaceEditRequest) { request in
                WorkspaceEditSheet(
                    title: request.title,
                    onCancel: {
                        workspaceEditRequest = nil
                    },
                    onSave: { title in
                        sessionStore.renameSession(id: request.id, title: title)
                        workspaceEditRequest = nil
                    }
                )
            }
            .sheet(item: $paneEditRequest) { request in
                PaneEditSheet(
                    title: request.currentTitle,
                    canReset: request.isUserEdited,
                    onCancel: { paneEditRequest = nil },
                    onReset: {
                        sessionStore.resetPaneTitle(
                            sessionID: request.sessionID,
                            paneID: request.paneID
                        )
                        paneEditRequest = nil
                    },
                    onSave: { newTitle in
                        sessionStore.renamePane(
                            sessionID: request.sessionID,
                            paneID: request.paneID,
                            title: newTitle
                        )
                        paneEditRequest = nil
                    }
                )
            }
            .sheet(item: $workspaceGroupCreateRequest) { _ in
                WorkspaceGroupCreateSheet(
                    existingGroupNames: sessionStore.groups.map(\.name),
                    onCancel: {
                        workspaceGroupCreateRequest = nil
                    },
                    onCreate: { groupName in
                        guard sessionStore.addWorkspaceGroup(named: groupName) != nil else {
                            return
                        }
                        appDelegate.surfacePrimaryWindow()
                        workspaceGroupCreateRequest = nil
                    }
                )
            }
            .sheet(item: $remoteWorkspaceGroupCreateRequest) { _ in
                RemoteWorkspaceGroupCreateSheet(
                    onCancel: {
                        remoteWorkspaceGroupCreateRequest = nil
                    },
                    onCreate: { name, target in
                        let groupName = name.isEmpty ? target.host : name
                        guard sessionStore.createRemoteWorkspaceGroup(named: groupName, target: target) != nil else {
                            return
                        }
                        appDelegate.surfacePrimaryWindow()
                        remoteWorkspaceGroupCreateRequest = nil
                    }
                )
            }
            .sheet(item: $sshWorkspaceConnectRequest) { request in
                SSHWorkspaceConnectSheet(
                    groupName: request.action.groupName,
                    initialDestination: request.initialDestination,
                    onCancel: { sshWorkspaceConnectRequest = nil },
                    onConnect: { target in
                        switch request.action {
                        case .convertPane(let sessionID, let paneID):
                            guard
                                let discardedPaneID = sessionStore.convertPaneToManagedSSH(
                                    sessionID: sessionID,
                                    paneID: paneID,
                                    target: target
                                )
                            else { return false }
                            ghosttyRuntime.discardSurface(for: discardedPaneID)
                        case .addToGroup(let groupID, _):
                            guard
                                sessionStore.addSSHSession(
                                    target: target,
                                    toGroupID: groupID
                                ) != nil
                            else { return false }
                        }
                        appDelegate.surfacePrimaryWindow()
                        sshWorkspaceConnectRequest = nil
                        return true
                    }
                )
            }
            .sheet(item: $workspaceGroupRenameRequest) { request in
                WorkspaceGroupRenameSheet(
                    groupName: request.name,
                    existingGroups: sessionStore.groups.map { ($0.id, $0.name) },
                    currentGroupID: request.id,
                    onCancel: {
                        workspaceGroupRenameRequest = nil
                    },
                    onSave: { groupName in
                        guard sessionStore.renameGroup(id: request.id, to: groupName) else {
                            return
                        }
                        workspaceGroupRenameRequest = nil
                    }
                )
            }
            .sheet(item: $quickSettingsRequest) { _ in
                QuickSettingsSheet()
                    .environment(appSettingsStore)
                    .appearanceBridge(appSettingsStore)
            }
            .onChange(of: isAnySheetPresented) { wasPresented, isPresented in
                guard wasPresented, !isPresented,
                    let session = sessionStore.selectedSession,
                    let paneID = session.activePane?.id
                else { return }
                requestManagedSSHWorkspaceOffer(sessionID: session.id, paneID: paneID)
            }
            .onAppear {
                // Give the floating-panel controllers the settings store so
                // their detached SwiftUI roots carry the appearance bridge
                // (accent, glow, UI font, text scale). See INT-237/INT-367.
                commandPaletteController.appSettingsStore = appSettingsStore
                keyboardCheatsheetController.appSettingsStore = appSettingsStore
                sessionManagerController.appSettingsStore = appSettingsStore
                worktreeManagerController.appSettingsStore = appSettingsStore
                appDelegate.bind(
                    sessionStore: sessionStore,
                    ghosttyRuntime: ghosttyRuntime,
                    floatingPanelController: floatingPanelController,
                    popUpTerminalController: popUpTerminalController,
                    appSettingsStore: appSettingsStore,
                    terminalAppearancePreferencesCache: terminalAppearancePreferencesCache,
                    openSettings: { openSettingsWindow() },
                    openPrimaryWindow: { openPrimaryWindow() }
                )
                appDelegate.updateDockBadge(total: sessionStore.unreadNotificationTotal)
                appDelegate.syncMenuBarMiniStatusItem()
                appDelegate.requestNotificationAuthorizationIfNeeded()
                let terminalSettings = appSettingsStore.terminal.value
                DaemonGarbageCollector.sweepIfEnabled(
                    store: sessionStore,
                    terminalSettings: terminalSettings,
                    isRestoreEnabled: appSettingsStore.general.value.restoreWorkspaces,
                    hasUnresolvedRecoveryWarning: recoveryWarning != nil,
                    pinned: DaemonPolicyStore().pinnedIDs
                )
                if recoveryWarning?.preventsInitialSave != true {
                    saveSessionIfRestoreEnabled()
                }
                presentRecoveryWarningIfNeeded()
            }
            .onChange(of: sessionStore.groups) { _, _ in
                saveSessionIfRestoreEnabled()
                floatingPanelController.evictFloatingSlotsForClosedWorkspaces(in: sessionStore)
                dismissWorkspaceEditorIfTargetClosed()
                dismissWorkspaceGroupEditorIfTargetClosed()
                dismissPaneEditorIfTargetClosed()
                appDelegate.evaluateAndPostNotifications()
                appDelegate.syncMenuBarMiniStatusItem()
            }
            .task(id: worktreeRepositorySelectionID) {
                await refreshWorktreeRepositoryContext()
            }
            // The refresh above intentionally no-ops while the manager is
            // visible (so it can't swap the hosted model out from under an
            // open panel). Once it closes, catch up: the selection may have
            // changed to a different repository while it was skipped, and
            // nothing else re-triggers the `.task(id:)` above for the SAME
            // selection ID the panel opened with.
            .onChange(of: worktreeManagerController.isVisible) { _, isVisible in
                guard !isVisible else { return }
                Task { await refreshWorktreeRepositoryContext() }
            }
            // Pins live outside the group array, so the groups onChange above
            // never fires for a pin/unpin — persist them on their own signal.
            .onChange(of: sessionStore.pinnedSessionIDs) { _, _ in
                saveSessionIfRestoreEnabled()
            }
            .onChange(of: sessionStore.selectedSessionID) { _, _ in
                saveSessionIfRestoreEnabled()
                // Per-workspace floating panel: show the new workspace's
                // panel if it's open, hide otherwise (without tearing the
                // previous workspace's slot down).
                floatingPanelController.activeWorkspaceDidChange(
                    relativeTo: NSApp.mainWindow ?? NSApp.keyWindow,
                    sessionStore: sessionStore,
                    ghosttyRuntime: ghosttyRuntime,
                    appSettingsStore: appSettingsStore
                )
            }
            .onChange(of: sessionStore.unreadNotificationTotal) { _, total in
                appDelegate.updateDockBadge(total: total)
            }
            .onChange(of: appSettingsStore.general.value.showMenuBarMiniStatus) { _, _ in
                appDelegate.syncMenuBarMiniStatusItem()
            }
            .onChange(of: appSettingsStore.workspaces.value.outputMarksNeedsAttention) { _, _ in
                appDelegate.evaluateAndPostNotifications()
            }
            .onChange(of: appSettingsStore.keyboard.value, initial: true) { _, keyboard in
                CurrentKeyboardShortcuts.keyboard = keyboard
            }
            .onChange(of: appSettingsStore.terminal.value.clipboardWritePolicy) { _, _ in
                ghosttyRuntime.applyTerminalSettings()
            }
            .onChange(of: appSettingsStore.terminal.value.confirmClipboardRead) { _, _ in
                ghosttyRuntime.applyTerminalSettings()
            }
            .onChange(of: appSettingsStore.terminal.value.copyOnSelect) { _, _ in
                ghosttyRuntime.applyTerminalSettings()
            }
            .onChange(of: appSettingsStore.appearance.value.accent, initial: true) { _, newAccent in
                // Single writer for the non-view-facing accent
                // mailbox. AppearanceBridge previously fired its own
                // .task here, which produced N writers when the
                // modifier was installed in multiple windows. Hoisting
                // the write to the primary scene root guarantees exactly
                // one update per accent change.
                AwAccentRuntime.current = AwAccent(configAccent: newAccent)
            }
            .onChange(of: appSettingsStore.appearance.value.uiFont) { _, newFamily in
                AwUIFontRuntime.current = AwUIFontResolver.resolvedForSystem(
                    rawFamily: newFamily
                )
            }
            .terminalAppearanceSync(
                appSettingsStore: appSettingsStore,
                ghosttyRuntime: ghosttyRuntime,
                preferencesCache: terminalAppearancePreferencesCache
            )
            .onReceive(NotificationCenter.default.publisher(for: .awesoMuxFocusSidebarRequested)) { _ in
                requestSidebarFocus()
            }
            .onReceive(NotificationCenter.default.publisher(for: .awesoMuxToggleSidebarWidthRequested)) { _ in
                requestSidebarWidthToggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .awesoMuxToggleSidebarVisibilityRequested)) { _ in
                requestSidebarVisibilityToggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .awesoMuxCommandPaletteRequested)) { _ in
                toggleCommandPalette()
            }
            .onReceive(NotificationCenter.default.publisher(for: .awesoMuxKeyboardCheatsheetRequested)) { _ in
                toggleKeyboardCheatsheet()
            }
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 8) {
                    if let quickRunToast {
                        QuickRunToastView(toast: quickRunToast)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if documentTabActions.noticeID != nil {
                        Text(DocumentComposeGuard.tabActionBlockedMessage)
                            .awFont(AwFont.Mono.meta)
                            .foregroundStyle(Color.aw.text)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                Color.aw.surface.elevated,
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(Color.aw.border, lineWidth: 0.5)
                            }
                            .accessibilityHidden(true)
                            .transition(.opacity)
                    }
                }
                .padding(.top, 18)
                .padding(.trailing, 18)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: quickRunToast)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: documentTabActions.noticeID)
            .preferredColorScheme(preferredScheme)
            .environment(appSettingsStore)
            .environment(documentTabActions)
            .appearanceBridge(appSettingsStore)
            .modifier(CaptureOpenWindowAction(action: $openWindowAction))
        }
        .windowStyle(.hiddenTitleBar)
        // A stable scene id lets Dock/menu code call `openWindow(id:)`, but it
        // would also make SwiftUI scene restoration durable enough to fight our
        // explicit PrimaryWindowFramePersistence/defaultWindowPlacement policy.
        .restorationBehavior(.disabled)
        // Use SwiftUI's placement hook for both first-launch sizing and our
        // stable manual frame restore. Restoring in `didBecomeKey` races the
        // scene's own late initial placement pass, which can snap the
        // window back to the default size after our `setFrame`.
        .defaultWindowPlacement { _, _ in
            PrimaryWindowFramePersistence.defaultPlacement()
        }
        .windowResizability(.contentMinSize)
        .commands {
            SettingsCommands()
            NewWorkspaceCommands(
                sessionStore: sessionStore,
                appSettingsStore: appSettingsStore,
                shortcut: shortcut(KeyboardShortcutCatalog.newWorkspace)
            )

            CommandGroup(after: .newItem) {
                Button("Open Markdown File…") {
                    openMarkdownFilePanel()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.openMarkdownFile))
                .disabled(sessionStore.selectedSession == nil)

                Button("Open in IDE…") {
                    openSelectedWorkspaceInIDE()
                }
                .disabled(!canOpenSelectedSessionInIDE || isAnySheetPresented)
            }

            // Cmd-W binding lives in `.saveItem` (the File-menu Save slot, which
            // awesoMux doesn't use) so SwiftUI's built-in Close-Window command
            // doesn't reclaim the chord. See `docs/adr/0002-window-close-keybinding-model.md`
            // for why Cmd-W = close-pane (last pane now closes the workspace via
            // closeWorkspace(_:) rather than the ADR's original silent recycle).
            //
            // Empty-state fallback: when no session is selected, Cmd-W closes
            // the app window via `performClose:` — the user has nothing to
            // close at the pane layer, and a swallowed shortcut is a worse
            // outcome than honouring the macOS muscle-memory of "Cmd-W
            // dismisses the foreground window."
            CommandGroup(replacing: .saveItem) {
                Button(closeShortcutTitle) {
                    closeActivePaneOrWindow()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.closePane))
            }

            CommandMenu("Workspace") {
                Button("New Workspace in Current Directory") {
                    sessionStore.addSession(
                        workingDirectory: sessionStore.selectedSession?.workingDirectory
                    )
                    appDelegate.surfacePrimaryWindow()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.newWorkspaceInCurrentDirectory))
                .disabled(sessionStore.selectedSession == nil)

                Button("New Workspace Group…") {
                    requestNewWorkspaceGroup()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.newWorkspaceGroup))
                .disabled(isAnySheetPresented)

                Button("New Remote Workspace Group…") {
                    requestNewRemoteWorkspaceGroup()
                }
                .disabled(isAnySheetPresented)

                Button("Connect via SSH…") { requestConnectViaSSH() }
                    .disabled(isAnySheetPresented)

                Button("Make This Workspace Managed…") {
                    requestManagedSSHWorkspaceConversion()
                }
                .disabled(selectedManagedSSHConversionTarget == nil || isAnySheetPresented)

                Button(
                    String(
                        localized: "Manage Worktrees…",
                        comment: "Workspace menu action that opens Worktree Manager."
                    )
                ) {
                    toggleWorktreeManager()
                }
                .disabled(worktreeManagerModel == nil || isAnySheetPresented)

                Divider()

                Button("Rename Workspace…") {
                    requestRenameSelectedWorkspace()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.renameWorkspace))
                .disabled(sessionStore.selectedSession == nil || isAnySheetPresented)

                Button(
                    sessionStore.selectedSession.map { sessionStore.isPinned($0.id) } == true
                        ? String(
                            localized: "Unpin Workspace",
                            comment: "Main-menu action that removes the selected workspace from the sidebar's pinned section.")
                        : String(
                            localized: "Pin Workspace",
                            comment: "Main-menu action that pins the selected workspace to the top of the sidebar.")
                ) {
                    guard let selected = sessionStore.selectedSession else { return }
                    sessionStore.togglePin(sessionID: selected.id)
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.togglePinWorkspace))
                .disabled(sessionStore.selectedSession == nil || isAnySheetPresented)

                Divider()

                Button("Close Workspace") {
                    closeSelectedSession()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.closeWorkspace))
                .disabled(sessionStore.selectedSessionID == nil || isAnySheetPresented)

                Button("Reopen Closed Workspace") {
                    reopenMostRecentlyClosedWorkspace()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.reopenClosedWorkspace))
                .disabled(!sessionStore.canReopenClosedWorkspace)

                // Non-most-recent reopen (INT-282). SwiftUI twin of the Dock
                // "Recent Workspaces" submenu; identity by sessionID, which is
                // unique per close (RecentlyClosedWorkspaceReducer.drain).
                let recentWorkspaces = sessionStore.recentWorkspaces(
                    limit: SessionStore.maxRecentlyClosed
                )
                Menu("Recently Closed") {
                    ForEach(recentWorkspaces, id: \.sessionID) { entry in
                        Button(DockRecentWorkspaceMenu.displayTitle(for: entry)) {
                            reopenRecentWorkspace(entry)
                        }
                    }
                }
                .disabled(recentWorkspaces.isEmpty)

                Divider()

                // Separated from the reversible actions above: Clear is the
                // one permanent, unrecoverable close (INT-282).
                Button("Clear Workspace") {
                    clearSelectedSession()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.clearWorkspace))
                .disabled(sessionStore.selectedSessionID == nil || isAnySheetPresented)

                Divider()

                Button("Split Right") {
                    splitActivePane(orientation: .vertical)
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.splitRight))
                .disabled(sessionStore.selectedSession == nil)

                Button("Split Down") {
                    splitActivePane(orientation: .horizontal)
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.splitDown))
                .disabled(sessionStore.selectedSession == nil)

                // Same conditional as the File-menu binding: closeActivePane()
                // routes single-pane sessions through closeWorkspace(_:), so
                // the title has to match what actually happens.
                Button(closePaneMenuTitle) {
                    closeActivePane()
                }
                .disabled(sessionStore.selectedSessionID == nil || isAnySheetPresented)

                Button("Find in Pane") {
                    presentFindInActivePane()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.find))
                .disabled(sessionStore.selectedSessionID == nil || isAnySheetPresented)

                Button("Show Scrollback") {
                    presentScrollbackDumpForActivePane()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.scrollbackDump))
                .disabled(sessionStore.selectedSessionID == nil || isAnySheetPresented)

                // Binds ⌘⌥R, which the palette already advertises — without this
                // menu item the shortcut was shown but not wired (Codex).
                Button("Rename Pane…") {
                    requestRenameActivePane()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.renamePane))
                .disabled(!selectedSessionHasMultiplePanes || isAnySheetPresented)

                Divider()

                Button("Grow Active Pane") {
                    sessionStore.resizeActiveSplit(by: 0.05)
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.growActivePane))
                .disabled(!selectedSessionHasMultiplePanes)

                Button("Shrink Active Pane") {
                    sessionStore.resizeActiveSplit(by: -0.05)
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.shrinkActivePane))
                .disabled(!selectedSessionHasMultiplePanes)

                Divider()

                Button("Previous Pane") {
                    sessionStore.focusPane(.previous)
                    announceActivePaneFocused()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.previousPane))
                .disabled(!selectedSessionHasMultiplePanes)

                Button("Next Pane") {
                    sessionStore.focusPane(.next)
                    announceActivePaneFocused()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.nextPane))
                .disabled(!selectedSessionHasMultiplePanes)

                Divider()

                // Keyboard access to the document tab strip (INT-748 PR2): the
                // strip's close buttons refuse first responder, so without
                // these commands keyboard users couldn't switch tabs at all.
                // Selection routes through selectDocumentTab, so the "Now
                // showing" VoiceOver announcement fires like any other path.
                Button("Previous Document Tab") {
                    selectAdjacentDocumentTab(offset: -1)
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.previousDocumentTab))
                .disabled(!selectedSessionHasMultipleDocumentTabs)

                Button("Next Document Tab") {
                    selectAdjacentDocumentTab(offset: 1)
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.nextDocumentTab))
                .disabled(!selectedSessionHasMultipleDocumentTabs)

                Button("Close Document Tab") {
                    closeSelectedDocumentTab()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.closeDocumentTab))
                .disabled(!selectedSessionHasDocumentTabs)

                Divider()

                Button("Move Pane Up") {
                    moveActivePane(toWorkspaceEdge: .up)
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.movePaneUp))
                .disabled(!canMoveActivePane(toWorkspaceEdge: .up))

                Button("Move Pane Down") {
                    moveActivePane(toWorkspaceEdge: .down)
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.movePaneDown))
                .disabled(!canMoveActivePane(toWorkspaceEdge: .down))

                Button("Move Pane Left") {
                    moveActivePane(toWorkspaceEdge: .left)
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.movePaneLeft))
                .disabled(!canMoveActivePane(toWorkspaceEdge: .left))

                Button("Move Pane Right") {
                    moveActivePane(toWorkspaceEdge: .right)
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.movePaneRight))
                .disabled(!canMoveActivePane(toWorkspaceEdge: .right))

                Button("Swap Pane With Next") {
                    swapActivePaneWithNext()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.swapPaneWithNext))
                .disabled(!canSwapActivePaneWithNext)

                Divider()

                if selectedSessionHasMultiplePanes {
                    ForEach(
                        Array(shortcuts(KeyboardShortcutCatalog.focusPaneBindings).enumerated()),
                        id: \.element.id
                    ) { offset, binding in
                        // The bindings are built from `(1...9)` in order, so the
                        // 0-based enumeration offset maps to pane index N = offset + 1.
                        // Compute it once rather than scatter `offset + 1`.
                        let paneIndex = offset + 1
                        Button(binding.action) {
                            if sessionStore.focusPane(at: paneIndex) {
                                announcePaneFocused(index: paneIndex)
                            }
                        }
                        .keyboardShortcut(binding)
                        // Gate on the real pane count, not just "has multiple":
                        // an enabled "Focus Pane 5" in a 3-pane session would
                        // silently no-op and erode trust in the shortcut family.
                        .disabled(paneIndex > selectedSessionPaneCount)
                    }

                    Divider()
                }

                Button("Acknowledge Workspace") {
                    if let id = sessionStore.selectedSessionID {
                        sessionStore.acknowledgeAllPanes(in: id)
                    }
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.acknowledgeWorkspace))
                .disabled(!selectedSessionNeedsAcknowledgement)

                Button("Clear All Notifications") {
                    sessionStore.acknowledgeAllSessions()
                }
                .disabled(sessionStore.unreadNotificationTotal == 0)

                Divider()

                Button(floatingPanelMenuTitle) {
                    toggleFloatingPanel()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.toggleFloatingPanel))
                .disabled(isAnySheetPresented)

                Button(popUpTerminalMenuTitle) {
                    togglePopUpTerminal()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.togglePopUpTerminal))
                .disabled(isAnySheetPresented)

                Button(commandPaletteMenuTitle) {
                    toggleCommandPalette()
                }
                // Interceptor-only by design: a real `.keyboardShortcut` here
                // would let AppKit route the same Cmd-K event through the menu
                // after `AwesoMuxApplication.sendEvent` posts the request.
                .disabled(isAnySheetPresented)

                Button("Session Manager") {
                    toggleSessionManager()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.sessionManager))
                .disabled(isAnySheetPresented)

                Divider()

                Button("Focus Sidebar", action: requestSidebarFocus)
                    .keyboardShortcut(shortcut(KeyboardShortcutCatalog.focusSidebar))
                    .disabled(
                        isAnySheetPresented || !sidebarCommandTargetAvailability.isAvailable)

                Button("Collapse/Expand Sidebar", action: requestSidebarWidthToggle)
                    .keyboardShortcut(shortcut(KeyboardShortcutCatalog.toggleSidebarWidth))
                    .disabled(
                        isAnySheetPresented || !sidebarCommandTargetAvailability.isAvailable)

                Button(sidebarVisibilityMenuTitle, action: requestSidebarVisibilityToggle)
                    .keyboardShortcut(shortcut(KeyboardShortcutCatalog.toggleSidebarVisibility))
                    .disabled(
                        isAnySheetPresented || !sidebarCommandTargetAvailability.isAvailable)

                let jumpRows = DockRecentWorkspaceMenu.openWorkspaceRows(
                    groups: sessionStore.groups,
                    pinnedSessionIDs: sessionStore.pinnedSessionIDs,
                    activeID: sessionStore.selectedSessionID
                )
                ForEach(
                    Array(shortcuts(KeyboardShortcutCatalog.jumpWorkspaces).enumerated()),
                    id: \.element.id
                ) { offset, binding in
                    // Label with the real workspace title ⌘N lands on; both this
                    // list and the jump action resolve through the same pinned-first
                    // order, so index ↔ title stays aligned. Out-of-range slots keep
                    // the generic "Jump to Workspace N" and stay disabled.
                    Button(offset < jumpRows.count ? jumpRows[offset].title : binding.action) {
                        runWorkspaceJumpShortcut(atFlatIndex: offset)
                    }
                    .keyboardShortcut(binding)
                    .disabled(!canRunWorkspaceShortcut(hasTarget: hasWorkspace(atFlatIndex: offset)))
                }

                Button("Previous Workspace") {
                    runPreviousWorkspaceShortcut()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.previousWorkspace))
                .disabled(!canRunWorkspaceShortcut(hasTarget: hasMultipleSessions))

                Button("Next Workspace") {
                    runNextWorkspaceShortcut()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.nextWorkspace))
                .disabled(!canRunWorkspaceShortcut(hasTarget: hasMultipleSessions))

                #if DEBUG
                    Divider()

                    // Debug-only test affordance. The notification policy +
                    // tracker chain (PR #29 / INT-183) and any future producer
                    // (INT-182) both depend on something flipping a session into
                    // .needsAttention. Until INT-182 lands, the only natural
                    // path is libghostty's bell handler — which Claude Code
                    // doesn't trigger for prompts. This button gives manual
                    // testers a way to exercise the notification chain end-to-end
                    // without waiting for the real producer.
                    Button("Debug: Fire Needs Attention on Active Workspace") {
                        if let id = sessionStore.selectedSessionID {
                            sessionStore.markSessionNeedsAttention(id: id, unreadNotificationDelta: 1)
                        }
                    }
                    .disabled(sessionStore.selectedSessionID == nil)

                    Button("Debug: Set Active Workspace Waiting") {
                        if let id = sessionStore.selectedSessionID {
                            sessionStore.setDebugAgentState(
                                id: id,
                                agentState: .waiting,
                                clearsAttention: true
                            )
                        }
                    }
                    .disabled(sessionStore.selectedSessionID == nil)
                #endif
            }

            CommandGroup(replacing: .help) {
                Button(keyboardCheatsheetMenuTitle) {
                    toggleKeyboardCheatsheet()
                }
                // Interceptor-only by design; see Command Palette above.
                .disabled(isAnySheetPresented)

                // Same URL and picker as the sidebar footer's feedback menu
                // (SidebarStatusFooter) — the Help menu just makes it
                // keyboard-reachable and discoverable outside the sidebar (INT-324).
                Button("Report a Bug or Suggest a Feature…") {
                    NSWorkspace.shared.open(SidebarStatusFooter.feedbackURL)
                }
            }
        }

        Window("Settings", id: AwesoMuxSceneID.settings) {
            AwesoMuxSettingsView()
                .environment(appSettingsStore)
                // Keys pane manages custom command shortcuts (INT-755).
                .environment(customCommandStore)
                // Notifications pane reads/writes per-workspace mute (INT-598).
                .environment(sessionStore)
                .environment(diagnosticsModel)
                .appearanceBridge(appSettingsStore)
        }
        .defaultSize(AwSettings.preferredWindowSize)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }

    private func closeSelectedSession() {
        guard let session = sessionStore.selectedSession else {
            return
        }
        closeWorkspace(session)
    }

    /// Single funnel for closing a workspace — keeps every entry point
    /// (Cmd-W, sidebar context menu, sidebar close button) consistent
    /// about evicting the floating-panel slot, freeing libghostty
    /// surfaces, and removing the session from the store. Without the
    /// floating-panel eviction, deleting a workspace strands its
    /// floating slot in the controller's per-workspace dict — silent
    /// PTY leak, ghost row in quit confirmation.
    ///
    /// Re-fetches the session by ID before the confirm gate so a sidebar
    /// row that captured a stale value can't slip an outdated `agentState`
    /// past the check. If the session is already gone (race with another
    /// close), bail silently.
    ///
    /// Single-argument overload so this can still be handed around as a
    /// bare `(TerminalSession) -> Void` closure (e.g. `ContentView`'s
    /// `onCloseWorkspace`) — a default parameter value doesn't survive that
    /// kind of reference in Swift.
    @MainActor
    private func closeWorkspace(_ session: TerminalSession) {
        closeWorkspace(session, alsoGateOnPaneActionConfirm: false)
    }

    /// - Parameter alsoGateOnPaneActionConfirm: Set from the ⌘W → single-pane
    ///   route only (`closeActivePane`). A user who set only "confirm before
    ///   closing panes" (not the workspace toggle) kept a protection the old
    ///   pane-scoped ⌘W path honored; the new last-pane-closes-workspace
    ///   routing must still see it.
    @MainActor
    private func closeWorkspace(_ session: TerminalSession, alsoGateOnPaneActionConfirm: Bool) {
        guard let live = sessionStore.session(id: session.id) else { return }
        let voTitle = Self.compactTitle(live.title)

        // Mirror the ⌘Q path: refresh per-pane prompt-marker quit state so
        // the close gate sees the same truth as `applicationShouldTerminate`.
        // Otherwise a busy `vim` pane in the same session is invisible to
        // the prompt — ⌘Q would prompt, ⌘W would not.
        ghosttyRuntime.refreshTerminalQuitConfirmationRisks(in: sessionStore)
        floatingPanelController.refreshTerminalQuitConfirmationRisks(using: ghosttyRuntime)

        guard let refreshed = sessionStore.session(id: live.id) else { return }

        let decision = confirmCloseIfNeeded(
            refreshed,
            alsoGateOnPaneActionConfirm: alsoGateOnPaneActionConfirm
        )
        guard let confirmed = sessionStore.session(id: refreshed.id) else {
            // `runModal` drains the run loop, so process exit can finish the
            // close while either alert button is being chosen.
            floatingPanelController.evictFloatingSlot(for: refreshed.id)
            announceClosed(title: voTitle)
            return
        }
        switch decision {
        case .suppressed:
            // Re-entry guard fired (another close-confirm is already on
            // screen). Don't announce a "cancel" — that would mislead a
            // VoiceOver user into thinking they made a decision.
            return
        case .userCancelled:
            announceCloseCancelled(title: voTitle)
            return
        case .proceed:
            break
        }
        floatingPanelController.evictFloatingSlot(for: confirmed.id)
        ghosttyRuntime.discardSurfaces(for: confirmed)
        sessionStore.closeSession(id: confirmed.id)
        announceClosed(title: voTitle)
    }

    private func clearSelectedSession() {
        guard let session = sessionStore.selectedSession else {
            return
        }
        clearWorkspace(session)
    }

    /// Permanent close (INT-282): mirrors `closeWorkspace(_:)` but skips the
    /// recently-closed capture and kills the pane daemons — main layout AND
    /// the workspace's floating slot, whose separate store `evictFloatingSlot`
    /// never kills — so there is no recovery path. Always confirms — soft
    /// close is undoable via ⌘⇧T, clear is not, and its chord is one modifier
    /// away from soft close.
    @MainActor
    private func clearWorkspace(_ session: TerminalSession) {
        guard let live = sessionStore.session(id: session.id) else { return }
        let voTitle = Self.compactTitle(live.title)

        ghosttyRuntime.refreshTerminalQuitConfirmationRisks(in: sessionStore)
        floatingPanelController.refreshTerminalQuitConfirmationRisks(using: ghosttyRuntime)

        guard let refreshed = sessionStore.session(id: live.id) else { return }

        switch confirmClearWorkspace(refreshed) {
        case .suppressed:
            return
        case .userCancelled:
            announceClearCancelled(title: voTitle)
            return
        case .proceed:
            break
        }
        // Re-fetch after the modal — `runModal` drains the run loop, so the
        // session can change (a split adds a pane whose daemon must die too)
        // or vanish entirely: a last-pane process exit soft-closes it through
        // `closeSession` and CAPTURES a reopen entry, which would let the
        // workspace the user just confirmed as unrecoverable come back via
        // ⌘⇧T. Honor the confirmed clear in that race: retract the captured
        // entry and still tear down the floating slot.
        guard let confirmed = sessionStore.session(id: refreshed.id) else {
            sessionStore.forgetRecentlyClosed(sessionID: refreshed.id)
            let floatingIDs = floatingPanelController.floatingDaemonIDs(for: refreshed.id)
            floatingPanelController.evictFloatingSlot(for: refreshed.id)
            killClearedDaemons(floatingIDs)
            announceCleared(title: voTitle)
            return
        }
        var daemonIDs: [TerminalSessionID] = []
        confirmed.layout.forEachPane { daemonIDs.append($0.terminalSessionID) }
        daemonIDs.append(contentsOf: floatingPanelController.floatingDaemonIDs(for: confirmed.id))
        floatingPanelController.evictFloatingSlot(for: confirmed.id)
        ghosttyRuntime.discardSurfaces(for: confirmed)
        sessionStore.closeSession(id: confirmed.id, captureRecentlyClosed: false)
        announceCleared(title: voTitle)
        killClearedDaemons(daemonIDs)
    }

    /// Fire-and-forget by design: the user confirmed an explicit destroy and
    /// the ids became unreachable in the same frame (no reopen entry, no live
    /// pane), so launch-time GC reaps any kill that fails or never runs (app
    /// quit mid-flight). Deliberately NO pre-kill revalidation, unlike
    /// `SessionManagerModel.reap`: nothing can reattach these ids, and the
    /// attach client may not have finished detaching yet, so a `clients == 0`
    /// guard would routinely skip live kills. Detached + fan-out mirrors
    /// `DaemonGarbageCollector` — kills are independent, one hung `amx kill`
    /// (2s timeout) must not serialize the rest.
    private func killClearedDaemons(_ daemonIDs: [TerminalSessionID]) {
        guard !daemonIDs.isEmpty else { return }
        // Captured here: the static logger is MainActor-isolated with the
        // rest of the App struct, and Logger itself is Sendable.
        let logger = Self.logger
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for id in daemonIDs {
                    group.addTask {
                        if await AmxBackend.killSession(id) == false {
                            logger.info("clear-workspace kill failed sessionID=\(id.rawValue, privacy: .public); launch GC will reap")
                        }
                    }
                }
            }
        }
    }

    /// Always shown, unlike `confirmCloseIfNeeded` — clearing is
    /// unrecoverable, so it is not gated on `confirmCloseWithRunningAgent`
    /// (that setting governs interruption warnings, not deletion). Adds the
    /// INT-214 activity line when the session is quit-risky. Same button
    /// order and keyboard behaviour as the close confirm (see its doc).
    ///
    /// `isCloseConfirmAlertPresented` is deliberately SHARED across close /
    /// clear / group-close confirms — a per-action flag would let a rapid
    /// double-invoke stack two modal alerts.
    @MainActor
    private func confirmClearWorkspace(_ session: TerminalSession) -> CloseConfirmDecision {
        guard !isCloseConfirmAlertPresented else { return .suppressed }
        isCloseConfirmAlertPresented = true
        defer { isCloseConfirmAlertPresented = false }

        let displayTitle = Self.sanitizedAlertTitle(session.title)
        let atRisk =
            session.isCloseRisk(at: Date())
            || floatingPanelController.hasRiskyFloatingSessionsOnClose(for: session.id)

        // One localized string per variant (not concatenated fragments) so
        // translators control the full sentence — mirrors confirmCloseIfNeeded.
        let body =
            atRisk
            ? String(
                localized:
                    "\(displayTitle) has activity that will be interrupted. The workspace will be closed permanently and can't be reopened. Its running sessions will be terminated.",
                comment:
                    "Body of the clear-workspace confirmation dialog when the workspace has running activity. Argument is the bidi-isolated workspace title."
            )
            : String(
                localized: "\(displayTitle) will be closed permanently and can't be reopened. Its running sessions will be terminated.",
                comment: "Body of the clear-workspace confirmation dialog. Argument is the bidi-isolated workspace title."
            )
        return NSAlert.confirmDestructive(
            title: String(
                localized: "Clear \(displayTitle)?",
                comment:
                    "Title of the clear-workspace (permanent close) confirmation dialog. Argument is the bidi-isolated workspace title."
            ),
            body: body,
            keyboardHint: String(
                localized: "Press ⌘Return to clear workspace. Esc cancels.",
                comment: "Keyboard hint line on the clear-workspace confirmation dialog."
            ),
            destructiveTitle: String(
                localized: "Clear Workspace",
                comment: "Destructive button on the clear-workspace confirmation dialog."
            )
        ) ? .proceed : .userCancelled
    }

    /// Closes every workspace in a group and removes the group (INT-206).
    ///
    /// Mirrors `closeWorkspace(_:)`: re-fetch the group by ID so a stale
    /// context-menu capture can't act on outdated membership, refresh
    /// prompt-marker quit state, then gate on one aggregate confirm before
    /// tearing down runtime surfaces and mutating the store. Empty groups
    /// confirm only when removal loses an SSH creation default.
    @MainActor
    private func closeWorkspaceGroup(_ group: SessionGroup) {
        guard let live = sessionStore.groups.first(where: { $0.id == group.id }) else { return }
        let voName = Self.compactTitle(live.name)

        if live.sessions.isEmpty {
            let remoteImpact = SessionGroupRemoteClosePresentation(
                summary: SessionGroupExecutionSummary(group: live),
                isEmpty: true
            )
            if remoteImpact.requiresConfirmation {
                switch confirmRemoteGroupImpact(live, isEmpty: true) {
                case .suppressed:
                    return
                case .userCancelled:
                    announceCloseCancelled(title: voName)
                    return
                case .proceed:
                    break
                }
            }
            guard let current = sessionStore.groups.first(where: { $0.id == live.id }) else { return }
            if remoteImpact.requiresConfirmation,
                SessionGroupCloseSafetySummary.hasMaterialChange(
                    from: live,
                    to: current,
                    confirmedSessionIDs: []
                )
            {
                showGroupCloseStateChanged()
                return
            }
            // `removeGroup` refuses the last group (stale context menu or
            // double-invoke can reach that here) — only announce a removal
            // that actually happened.
            if sessionStore.removeGroup(id: current.id) {
                announceGroupClosed(name: voName)
            }
            return
        }

        ghosttyRuntime.refreshTerminalQuitConfirmationRisks(in: sessionStore)
        floatingPanelController.refreshTerminalQuitConfirmationRisks(using: ghosttyRuntime)

        guard let refreshed = sessionStore.groups.first(where: { $0.id == group.id }) else { return }
        // The user confirms exactly this membership; the alert's risk count
        // is computed from it. `runModal` keeps draining the main queue, so
        // a session can still JOIN the group mid-modal — it was never part
        // of what the user agreed to destroy, so it must survive the close
        // (its presence also keeps the group alive via `removeGroup`'s
        // emptiness guard).
        let confirmedIDs = refreshed.sessions.map(\.id)

        switch confirmCloseGroupIfNeeded(refreshed) {
        case .suppressed:
            return
        case .userCancelled:
            announceCloseCancelled(title: voName)
            return
        case .proceed:
            break
        }
        // Re-fetch live state AFTER the modal and close exactly the
        // intersection of confirmed IDs with current group membership:
        // pane recycling mid-modal can swap surfaces (a pre-modal snapshot
        // would leak the replacement), and a confirmed session that LEFT
        // the group mid-modal must keep its surfaces — only sessions we
        // both confirmed and still own get torn down. No awaits between
        // here and closeGroup, so the two operate on the same set.
        guard let liveGroup = sessionStore.groups.first(where: { $0.id == refreshed.id }) else { return }
        let confirmedSet = Set(confirmedIDs)
        if SessionGroupCloseSafetySummary.hasMaterialChange(
            from: refreshed,
            to: liveGroup,
            confirmedSessionIDs: confirmedSet
        ) {
            showGroupCloseStateChanged()
            return
        }
        let sessionsToClose = liveGroup.sessions.filter { confirmedSet.contains($0.id) }
        for session in sessionsToClose {
            floatingPanelController.evictFloatingSlot(for: session.id)
            ghosttyRuntime.discardSurfaces(for: session)
        }
        if sessionStore.closeGroup(id: liveGroup.id, limitedTo: sessionsToClose.map(\.id)) {
            announceGroupClosed(name: voName)
        } else if sessionsToClose.isEmpty {
            // Every confirmed session was already closed or moved away and
            // the group couldn't be removed — this action did nothing, so
            // announce nothing.
            return
        } else if sessionStore.groups.first(where: { $0.id == liveGroup.id })?.sessions.isEmpty == true {
            // Sole-group case: the store refuses to remove the last group,
            // so the empty shell survives.
            announceAllWorkspacesClosed(inGroup: voName)
        } else {
            // A workspace joined mid-modal and keeps the group populated —
            // claiming "all workspaces" closed would be false.
            postAccessibilityAnnouncement(
                LocalizedPluralStrings.closeGroupWorkspacesClosed(count: sessionsToClose.count)
            )
        }
    }

    /// Group-scale variant of `confirmCloseIfNeeded(_:)` — one aggregate
    /// alert instead of N per-workspace alerts. Uses `isCloseRisk(at:)` —
    /// this flow destroys the sessions (soft-close orphans a bridged
    /// daemon; reopen mints a fresh id and never reattaches), so bridged
    /// panes are not safe here, unlike the `⌘Q` quit path which keeps
    /// `isQuitRisk`. Shares the `isCloseConfirmAlertPresented` re-entry
    /// guard so a group confirm can't stack on top of a per-workspace one.
    @MainActor
    private func confirmCloseGroupIfNeeded(_ group: SessionGroup) -> CloseConfirmDecision {
        let workspaces = appSettingsStore.workspaces.value
        let now = Date()
        let riskyCount =
            workspaces.confirmCloseWithRunningAgent
            ? group.sessions.count(where: {
                $0.isCloseRisk(at: now) || floatingPanelController.hasRiskyFloatingSessionsOnClose(for: $0.id)
            })
            : 0
        let remoteImpact = SessionGroupRemoteClosePresentation(
            summary: SessionGroupExecutionSummary(group: group),
            isEmpty: false
        )
        guard riskyCount > 0 else {
            // The running-agent preference controls interruption prompts, not
            // remote pane destruction or loss of the group's SSH default.
            if remoteImpact.requiresConfirmation {
                return confirmRemoteGroupImpact(group, isEmpty: false)
            }
            return .proceed
        }

        guard !isCloseConfirmAlertPresented else { return .suppressed }
        isCloseConfirmAlertPresented = true
        defer { isCloseConfirmAlertPresented = false }

        let displayName = Self.sanitizedAlertTitle(group.name)

        var body = LocalizedPluralStrings.closeGroupRiskyWorkspaces(count: riskyCount)
        if let remoteLossText = remoteImpact.lossText {
            // One dialog covers both running work and the exact remote impact.
            body += "\n\n" + remoteLossText
        }
        return NSAlert.confirmDestructive(
            title: String(
                localized: "Close group \(displayName)?",
                comment:
                    "Title of the close-group confirmation dialog when workspaces in the group have running activity. Argument is the bidi-isolated group name."
            ),
            body: body,
            keyboardHint: String(
                localized: "Press ⌘Return to close group. Esc cancels.",
                comment: "Keyboard hint line on the close-group confirmation dialog."
            ),
            destructiveTitle: String(
                localized: "Close Group",
                comment: "Destructive button on the close-group confirmation dialog."
            )
        ) ? .proceed : .userCancelled
    }

    /// Confirms active remote pane destruction and/or loss of an SSH creation
    /// default. Pane plans describe live work; the group target is only the
    /// default that removal forgets.
    @MainActor
    private func confirmRemoteGroupImpact(_ group: SessionGroup, isEmpty: Bool) -> CloseConfirmDecision {
        guard !isCloseConfirmAlertPresented else { return .suppressed }
        isCloseConfirmAlertPresented = true
        defer { isCloseConfirmAlertPresented = false }

        let displayName = Self.sanitizedAlertTitle(group.name)
        let impact = SessionGroupRemoteClosePresentation(
            summary: SessionGroupExecutionSummary(group: group),
            isEmpty: isEmpty
        )
        guard let lossText = impact.lossText else { return .proceed }

        // "Remove" for an empty group (nothing closes but the shell of the
        // group itself); "Close" when workspaces are about to be torn down —
        // matching the risky-path dialog's verb for the same operation.
        let title =
            isEmpty
            ? String(
                localized: "Remove group \(displayName)?",
                comment:
                    "Title of the confirmation dialog shown when removing an empty workspace group with an SSH creation default. Argument is the bidi-isolated group name."
            )
            : String(
                localized: "Close group \(displayName)?",
                comment:
                    "Title of the confirmation dialog shown when closing a workspace group with remote impact. Argument is the bidi-isolated group name."
            )
        let keyboardHint =
            isEmpty
            ? String(
                localized: "Press ⌘Return to remove group. Esc cancels.",
                comment: "Keyboard hint line on the empty-group removal confirmation dialog."
            )
            : String(
                localized: "Press ⌘Return to close group. Esc cancels.",
                comment: "Keyboard hint line on the close-group confirmation dialog."
            )
        let destructiveTitle =
            isEmpty
            ? String(
                localized: "Remove Group",
                comment: "Destructive button on the empty-group removal confirmation dialog."
            )
            : String(
                localized: "Close Group",
                comment: "Destructive button on the close-group confirmation dialog."
            )

        return NSAlert.confirmDestructive(
            title: title,
            body: lossText,
            keyboardHint: keyboardHint,
            destructiveTitle: destructiveTitle
        ) ? .proceed : .userCancelled
    }

    @MainActor
    private func showGroupCloseStateChanged() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Group locations changed",
            comment: "Title of the notice shown when a group changes while its close confirmation is open."
        )
        alert.informativeText = String(
            localized: "Review the group's current local and remote panes, then close it again.",
            comment: "Body of the notice shown when a group changes while its close confirmation is open."
        )
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss alert button"))
        alert.runModal()
    }

    private enum CloseConfirmDecision {
        case proceed
        case userCancelled
        case suppressed
    }

    /// Returns `true` when the close should proceed. Snapshots quit-risk
    /// state at modal-open time intentionally — if the agent finishes
    /// during the (potentially long) modal display, we still close.
    /// Predictable UX beats "you confirmed close but we silently bailed
    /// because the agent happened to finish a moment later."
    ///
    /// Uses `isCloseRisk(at:)` — this flow destroys the session
    /// (soft-close orphans a bridged daemon; reopen mints a fresh id and
    /// never reattaches), so bridged panes are not safe here, unlike the
    /// `⌘Q` quit path which keeps `isQuitRisk`. The per-pane check
    /// otherwise combines the pane's `agentExecutionState` (active states
    /// are risky), its prompt-marker quit state
    /// (`needsTerminalQuitConfirmation`), and 60-second staleness aging from
    /// INT-217. Doing the same here means ⌘W on a busy `vim` pane prompts even
    /// when the agent is `.idle`.
    ///
    /// Button order is **Cancel added first** so NSAlert's natural
    /// "first-button-is-default" behavior wires Return → Cancel without
    /// any post-hoc `keyEquivalent` surgery. Esc → Cancel comes from
    /// NSAlert's localized-"Cancel" title fallback (the button literally
    /// titled with the locale's "Cancel" string is treated as the cancel
    /// key target). This matches the macOS destructive-action convention
    /// (Empty Trash, Move to Trash): Cancel is the safe default; the
    /// destructive verb is on the right but not the default.
    ///
    /// The workspace title is bidi-isolated (`U+2068` … `U+2069`) for
    /// the dialog text — an RTL or control-character title can't reorder
    /// the surrounding LTR template — and trimmed to 60 chars so a
    /// paste-bombed title can't blow out the dialog layout. The bidi
    /// isolates are dialog-only; the VoiceOver announcement uses
    /// `compactTitle` (newline-strip + truncate, no isolate codepoints
    /// since they don't help speech and may add spoken artifacts).
    /// - Parameter alsoGateOnPaneActionConfirm: When true, also treat
    ///   `confirmDestructivePaneActionWithRunningAgent` as a gate — the
    ///   ⌘W → single-pane route (see `closeWorkspace(_:alsoGateOnPaneActionConfirm:)`).
    @MainActor
    private func confirmCloseIfNeeded(
        _ session: TerminalSession,
        alsoGateOnPaneActionConfirm: Bool = false
    ) -> CloseConfirmDecision {
        let workspaces = appSettingsStore.workspaces.value
        // Check both the main session AND any backgrounded floating-panel
        // session bound to this workspace. `evictFloatingSlot` tears down
        // floating sessions unconditionally as part of close, so a workspace
        // with an idle sidebar pane but a running agent in its floating slot
        // would otherwise be killed silently. Close-scoped (see doc above),
        // unlike the ⌘Q path's `floatingPanelController.sessionsAtRiskOnQuit`.
        let mainAtRisk = session.isCloseRisk(at: Date())
        let floatingAtRisk = floatingPanelController.hasRiskyFloatingSessionsOnClose(for: session.id)
        let confirmEnabled =
            workspaces.confirmCloseWithRunningAgent
            || (alsoGateOnPaneActionConfirm && workspaces.confirmDestructivePaneActionWithRunningAgent)
        guard confirmEnabled,
            mainAtRisk || floatingAtRisk
        else {
            return .proceed
        }

        guard !isCloseConfirmAlertPresented else { return .suppressed }
        isCloseConfirmAlertPresented = true
        defer { isCloseConfirmAlertPresented = false }

        let displayTitle = Self.sanitizedAlertTitle(session.title)

        return NSAlert.confirmDestructive(
            title: String(
                localized: "Close \(displayTitle)?",
                comment:
                    "Title of the close-workspace confirmation dialog when the workspace has running activity. Argument is the bidi-isolated workspace title."
            ),
            body: String(
                localized: "\(displayTitle) has activity that will be interrupted. Closing will terminate the running process.",
                comment: "Body of the close-workspace confirmation dialog. Argument is the bidi-isolated workspace title."
            ),
            keyboardHint: String(
                localized: "Press ⌘Return to close workspace. Esc cancels.",
                comment: "Keyboard hint line on the close-workspace confirmation dialog."
            ),
            destructiveTitle: String(
                localized: "Close Workspace",
                comment: "Destructive button on the close-workspace confirmation dialog."
            )
        ) ? .proceed : .userCancelled
    }

    @MainActor
    private func confirmDestructivePaneActionIfNeeded(
        _ action: DestructivePaneActionConfirmationPolicy.Action,
        in session: TerminalSession,
        atRisk: Bool
    ) -> CloseConfirmDecision {
        guard !isCloseConfirmAlertPresented else { return .suppressed }
        isCloseConfirmAlertPresented = true
        defer { isCloseConfirmAlertPresented = false }

        let displayTitle = Self.sanitizedAlertTitle(session.title)

        let title: String
        let body: String
        switch action {
        case .restartShell:
            title = String(
                localized: "Restart shell in \(displayTitle)?",
                comment:
                    "Title of the restart-shell confirmation dialog when the active pane has running activity. Argument is the bidi-isolated workspace title."
            )
            // One localized string per variant (not concatenated fragments) so
            // translators control the full sentence — mirrors confirmClearWorkspace.
            // The idle variant is honest about `recycleAndAnnounce` discarding the
            // old surface: a restart mints a fresh libghostty surface, so scrollback
            // does not carry over.
            body =
                atRisk
                ? String(
                    localized:
                        "\(displayTitle) has activity that will be interrupted. Restarting the shell will terminate the running process.",
                    comment:
                        "Body of the restart-shell confirmation dialog when the active pane has running activity. Argument is the bidi-isolated workspace title."
                )
                : String(
                    localized:
                        "Restarting the shell in \(displayTitle) ends the current session and starts a fresh one. Scrollback isn't kept.",
                    comment:
                        "Body of the restart-shell confirmation dialog when the active pane is idle. Argument is the bidi-isolated workspace title."
                )
        case .closePane:
            title = String(
                localized: "Close pane in \(displayTitle)?",
                comment:
                    "Title of the close-pane confirmation dialog when the active pane has running activity. Argument is the bidi-isolated workspace title."
            )
            body = String(
                localized:
                    "The active pane in \(displayTitle) has activity that will be interrupted. Closing the pane will terminate the running process.",
                comment: "Body of the close-pane confirmation dialog. Argument is the bidi-isolated workspace title."
            )
        }

        return NSAlert.confirmDestructive(
            title: title,
            body: body,
            keyboardHint: action.keyboardHint,
            destructiveTitle: action.destructiveButtonTitle
        ) ? .proceed : .userCancelled
    }

    /// Newline-strip + truncate to 60 characters with ellipsis. The
    /// non-bidi-isolated form used for VoiceOver announcements so
    /// `U+2068`/`U+2069` codepoints don't show up as spoken artifacts.
    private static func compactTitle(_ raw: String) -> String {
        let oneLine =
            raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return oneLine.count > 60
            ? String(oneLine.prefix(60)) + "…"
            : oneLine
    }

    /// Dialog-text variant of `compactTitle` — wraps the compacted title
    /// in `U+2068` … `U+2069` so an RTL or control-character title can't
    /// reorder the surrounding LTR template.
    static func sanitizedAlertTitle(_ raw: String) -> String {
        // U+2068 FIRST STRONG ISOLATE … U+2069 POP DIRECTIONAL ISOLATE.
        "\u{2068}\(compactTitle(raw))\u{2069}"
    }

    private func announceClosed(title: String) {
        let announcement = String(
            localized: "Closed workspace \(title)",
            comment: "VoiceOver announcement after a workspace is closed; argument is the workspace title."
        )
        postAccessibilityAnnouncement(announcement)
    }

    private func announceCleared(title: String) {
        let announcement = String(
            localized: "Cleared workspace \(title)",
            comment: "VoiceOver announcement after a workspace is permanently closed with no reopen path; argument is the workspace title."
        )
        postAccessibilityAnnouncement(announcement)
    }

    private func announceClearCancelled(title: String) {
        let announcement = String(
            localized: "Clear cancelled for \(title)",
            comment:
                "VoiceOver announcement when the user cancels the clear-workspace confirmation dialog; argument is the workspace title."
        )
        postAccessibilityAnnouncement(announcement)
    }

    private func announceGroupClosed(name: String) {
        let announcement = String(
            localized: "Closed workspace group \(name)",
            comment: "VoiceOver announcement after a workspace group is closed; argument is the group name."
        )
        postAccessibilityAnnouncement(announcement)
    }

    private func announceAllWorkspacesClosed(inGroup name: String) {
        let announcement = String(
            localized: "Closed all workspaces in \(name)",
            comment:
                "VoiceOver announcement after closing every workspace in the sole group, which remains as an empty group; argument is the group name."
        )
        postAccessibilityAnnouncement(announcement)
    }

    private func announceCloseCancelled(title: String) {
        let announcement = String(
            localized: "Close cancelled for \(title)",
            comment:
                "VoiceOver announcement when the user cancels a close confirmation dialog; argument is the workspace title or workspace group name."
        )
        postAccessibilityAnnouncement(announcement)
    }

    private func postAccessibilityAnnouncement(_ announcement: String) {
        TerminalAccessibilityAnnouncer.announce(announcement)
    }

    /// Pops the head of the recently-closed buffer and inserts a fresh
    /// workspace rebuilt from its captured layout. The store path mints new
    /// session/split/pane UUIDs and re-validates per-pane working directories
    /// (missing paths fall back to `~`); libghostty surfaces will be spawned
    /// lazily by `GhosttySurfaceView` on render, so no preemptive runtime
    /// wiring is needed here.
    ///
    /// VoiceOver announcement on completion: a sighted user gets sidebar
    /// movement + selection-highlight feedback for free; a VoiceOver user
    /// without this post would get only the menu-dismiss sound and no idea
    /// what happened. Mirrors `scheduleDockBadgeAnnouncement`'s pattern.
    /// Posting on `.main` keeps the announcement queued after the menu has
    /// dismissed so it isn't swallowed by the menu's own AX traffic.
    private func reopenMostRecentlyClosedWorkspace() {
        let restoredID = sessionStore.reopenMostRecentlyClosed()
        if restoredID != nil {
            appDelegate.surfacePrimaryWindow()
        }
        DispatchQueue.main.async {
            let announcement: String
            if let restoredID,
                let session = self.sessionStore.session(id: restoredID)
            {
                announcement = String(
                    localized: "Reopened workspace \(Self.compactTitle(session.title))",
                    comment: "VoiceOver announcement after Cmd-Shift-T reopens a closed workspace; argument is the workspace title."
                )
            } else {
                announcement = String(
                    localized: "No recently closed workspace to reopen",
                    comment: "VoiceOver announcement when Cmd-Shift-T is invoked but the recently-closed cache is empty or fully expired."
                )
            }
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: announcement,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ]
            )
        }
    }

    /// Targeted reopen for the "Recently Closed" submenu and its palette twin
    /// (INT-282). Same semantics as `dockReopenRecentWorkspace(_:)`: the entry
    /// may have been reopened or aged out since the list was built — `reopen`
    /// returns nil then, so beep instead of surfacing the window. VoiceOver
    /// announcement mirrors `reopenMostRecentlyClosedWorkspace`.
    private func reopenRecentWorkspace(_ entry: RecentlyClosedWorkspace) {
        let restoredID = sessionStore.reopen(entry)
        guard restoredID != nil else {
            signalReopenEntryUnavailable()
            return
        }
        appDelegate.surfacePrimaryWindow()
        DispatchQueue.main.async {
            guard let restoredID,
                let session = self.sessionStore.session(id: restoredID)
            else {
                return
            }
            let announcement = String(
                localized: "Reopened workspace \(Self.compactTitle(session.title))",
                comment:
                    "VoiceOver announcement after a recently-closed workspace is reopened from the picker; argument is the workspace title."
            )
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: announcement,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ]
            )
        }
    }

    /// Feedback for a Recently Closed entry that went stale between list
    /// build and selection (reopened from another surface, or TTL-expired).
    /// The beep alone is invisible to VoiceOver — announce the miss so a
    /// screen-reader user can tell "stale entry" from "nothing happened".
    /// Deferred like the reopen success path so the menu's own AX traffic
    /// doesn't swallow it.
    private func signalReopenEntryUnavailable() {
        NSSound.beep()
        DispatchQueue.main.async {
            let announcement = String(
                localized: "That workspace is no longer available to reopen",
                comment: "VoiceOver announcement when a Recently Closed entry was already reopened or expired before the user selected it."
            )
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: announcement,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ]
            )
        }
    }

    private var selectedSessionHasMultiplePanes: Bool {
        sessionStore.selectedSession?.layout.hasMultiplePanes ?? false
    }

    private var selectedSessionPaneCount: Int {
        sessionStore.selectedSession?.layout.paneCount ?? 0
    }

    private var selectedSessionHasMultipleDocumentTabs: Bool {
        (sessionStore.selectedSession?.layout.firstDocumentGroup?.tabs.count ?? 0) > 1
    }

    private var selectedSessionHasDocumentTabs: Bool {
        sessionStore.selectedSession?.layout.firstDocumentGroup != nil
    }

    private var canOpenSelectedSessionInIDE: Bool {
        guard appSettingsStore.workspaces.value.openInIDEEnabled,
            let session = sessionStore.selectedSession
        else {
            return false
        }
        return IDEOpenTarget.isEligible(session: session)
    }

    /// Cycles the selected session's document viewer to the tab `offset`
    /// positions away, wrapping at both ends (INT-748 PR2). No-ops while a
    /// comment draft is open: switching remounts the document view and would
    /// silently destroy typed text — the same protection `DocumentComposeGuard`
    /// gives agent-driven opens, which keyboard selection would otherwise
    /// bypass (review finding). A mouse selection involves a click that has
    /// already dismissed the transient popover, so it needs no guard.
    private func selectAdjacentDocumentTab(offset: Int) {
        documentTabActions.perform {
            guard let session = sessionStore.selectedSession,
                let targetTabID = session.layout.firstDocumentGroup?.adjacentTabID(offset: offset)
            else {
                return
            }
            sessionStore.selectDocumentTab(tabID: targetTabID, in: session.id)
        }
    }

    /// Closes the selected document tab — the keyboard counterpart of the tab
    /// pill's close X, which refuses first responder (INT-562) and is
    /// therefore unreachable with Full Keyboard Access (review finding).
    /// Same compose-draft guard as tab cycling: closing the selected tab
    /// destroys an open draft.
    private func closeSelectedDocumentTab() {
        documentTabActions.perform {
            guard let session = sessionStore.selectedSession,
                let selectedTab = session.layout.firstDocumentGroup?.selectedTab
            else {
                return
            }
            sessionStore.closeDocumentPane(documentID: selectedTab.id, in: session.id)
            // Same announcement as the pill's close X (TerminalPaneView) so the
            // outcome is spoken regardless of which affordance closed the tab.
            TerminalAccessibilityAnnouncer.announce(
                String(
                    localized: "Closed \(selectedTab.title)",
                    comment: "VoiceOver announcement after closing a document tab"
                )
            )
        }
    }

    private func announcePaneFocused(index: Int) {
        let announcement = String(
            localized: "Focused pane \(index)",
            comment: "VoiceOver announcement when the user jumps to a specific split pane by index."
        )
        postAccessibilityAnnouncement(announcement)
    }

    /// Announces the index of whatever pane is active *now*, for the directional
    /// (prev/next) commands that move relative to the current pane rather than
    /// to a known index. These buttons are gated on a multi-pane session and
    /// always land on a different pane, so the announcement is always a real move.
    private func announceActivePaneFocused() {
        guard let session = sessionStore.selectedSession,
            let index = session.layout.paneIDs.firstIndex(of: session.activePaneID)
        else {
            return
        }
        announcePaneFocused(index: index + 1)
    }

    private func canMoveActivePane(toWorkspaceEdge edge: PaneMoveEdge) -> Bool {
        guard let session = sessionStore.selectedSession else {
            return false
        }
        return sessionStore.canMovePane(
            id: session.activePaneID,
            toWorkspaceEdge: edge,
            in: session.id
        )
    }

    /// Keyboard pane moves use the workspace-edge semantic: the active pane is
    /// detached and re-dropped against the far edge of the whole workspace. The
    /// store moves focus to the relocated pane, so the announcement reflects
    /// where it landed.
    private func moveActivePane(toWorkspaceEdge edge: PaneMoveEdge) {
        guard let session = sessionStore.selectedSession else {
            return
        }
        guard
            sessionStore.movePane(
                id: session.activePaneID,
                toWorkspaceEdge: edge,
                in: session.id
            )
        else {
            return
        }
        announcePaneMoved(toWorkspaceEdge: edge)
    }

    private func announcePaneMoved(toWorkspaceEdge edge: PaneMoveEdge) {
        let announcement: String
        switch edge {
        case .up:
            announcement = String(
                localized: "Moved pane to top",
                comment: "VoiceOver announcement after moving the active pane to the top edge of the workspace."
            )
        case .down:
            announcement = String(
                localized: "Moved pane to bottom",
                comment: "VoiceOver announcement after moving the active pane to the bottom edge of the workspace."
            )
        case .left:
            announcement = String(
                localized: "Moved pane to left",
                comment: "VoiceOver announcement after moving the active pane to the left edge of the workspace."
            )
        case .right:
            announcement = String(
                localized: "Moved pane to right",
                comment: "VoiceOver announcement after moving the active pane to the right edge of the workspace."
            )
        }
        postAccessibilityAnnouncement(announcement)
    }

    /// The pane that follows the active pane in depth-first order, wrapping past
    /// the last pane back to the first. Nil for a single-pane session (nothing to
    /// swap with). Mirrors the drag-path center-drop swap as a keyboard action.
    private func nextPaneIDForSwap(
        in session: TerminalSession
    ) -> (index: Int, id: TerminalPane.ID)? {
        let paneIDs = session.layout.paneIDs
        guard paneIDs.count > 1,
            let activeIndex = paneIDs.firstIndex(of: session.activePaneID)
        else {
            return nil
        }
        let nextIndex = (activeIndex + 1) % paneIDs.count
        return (nextIndex, paneIDs[nextIndex])
    }

    private var canSwapActivePaneWithNext: Bool {
        guard let session = sessionStore.selectedSession,
            let next = nextPaneIDForSwap(in: session)
        else {
            return false
        }
        return sessionStore.canSwapPanes(
            firstID: session.activePaneID,
            secondID: next.id,
            in: session.id
        )
    }

    private func swapActivePaneWithNext() {
        guard let session = sessionStore.selectedSession,
            let next = nextPaneIDForSwap(in: session),
            sessionStore.swapPanes(
                firstID: session.activePaneID,
                secondID: next.id,
                in: session.id
            )
        else {
            return
        }
        // `next.index` is the depth-first position the swap moved the active
        // pane's contents into — announce that 1-based slot, matching the
        // existing `Focused pane N` idiom.
        let announcement = String(
            localized: "Swapped with pane \(next.index + 1)",
            comment:
                "VoiceOver announcement after swapping the active pane with the next pane in depth-first order; argument is the 1-based pane index."
        )
        postAccessibilityAnnouncement(announcement)
    }

    private var selectedSessionNeedsAcknowledgement: Bool {
        guard let session = sessionStore.selectedSession else {
            return false
        }
        return session.unreadNotificationCount > 0 || session.needsAcknowledgement
    }

    private var selectedManagedSSHConversionTarget: RemoteTarget? {
        guard let session = sessionStore.selectedSession else { return nil }
        return sessionStore.managedSSHConversionTarget(
            sessionID: session.id,
            paneID: session.activePaneID
        )
    }

    // Counts sessions across all groups, not groups: "Previous/Next Workspace"
    // walks the flattened session list, so the commands are only meaningful when
    // there's more than one session to move between.
    private var hasMultipleSessions: Bool {
        sessionStore.groups.reduce(0) { count, group in
            count + group.sessions.count
        } > 1
    }

    private func hasWorkspace(atFlatIndex index: Int) -> Bool {
        index >= 0
            && index
                < sessionStore.groups.reduce(0) { count, group in
                    count + group.sessions.count
                }
    }

    private func canRunWorkspaceShortcut(hasTarget: Bool) -> Bool {
        WorkspaceCommandShortcutPolicy.canRun(
            isAnySheetPresented: isAnySheetPresented,
            isCommandPaletteVisible: commandPaletteController.isVisible,
            hasTarget: hasTarget
        )
    }

    private func runWorkspaceJumpShortcut(atFlatIndex index: Int) {
        guard canRunWorkspaceShortcut(hasTarget: hasWorkspace(atFlatIndex: index)) else {
            return
        }
        selectWorkspace(atFlatIndex: index)
    }

    private func runPreviousWorkspaceShortcut() {
        guard canRunWorkspaceShortcut(hasTarget: hasMultipleSessions) else {
            return
        }
        selectWorkspaceRelative(offset: -1)
        if sessionStore.selectedSessionID != nil {
            appDelegate.surfacePrimaryWindowIfNotVisible()
        }
    }

    private func runNextWorkspaceShortcut() {
        guard canRunWorkspaceShortcut(hasTarget: hasMultipleSessions) else {
            return
        }
        selectWorkspaceRelative(offset: 1)
        if sessionStore.selectedSessionID != nil {
            appDelegate.surfacePrimaryWindowIfNotVisible()
        }
    }

    // ⌘1-9 jump and Previous/Next resolve from the sidebar's pinned-first visual
    // order (INT-737) so a ⌘-digit lands on the tile showing that badge. Stays
    // filter-blind — as this action side always was — since the sidebar's
    // filtered badge snapshot is view-local and out of scope to thread here.
    private func workspaceNavigationOrder() -> [TerminalSession.ID] {
        WorkspaceNavigationOrder.pinnedFirstSessionIDs(
            in: sessionStore.groups,
            pinnedSessionIDs: sessionStore.pinnedSessionIDs
        )
    }

    private func selectWorkspace(atFlatIndex index: Int) {
        let order = workspaceNavigationOrder()
        guard order.indices.contains(index) else {
            return
        }
        sessionStore.selectedSessionID = order[index]
    }

    private func selectWorkspaceRelative(offset: Int) {
        let order = workspaceNavigationOrder()
        guard order.count > 1 else {
            sessionStore.selectedSessionID = order.first
            return
        }
        guard let current = sessionStore.selectedSessionID,
            let currentIndex = order.firstIndex(of: current)
        else {
            sessionStore.selectedSessionID = order.first
            return
        }
        let count = order.count
        let nextIndex = ((currentIndex + offset) % count + count) % count
        sessionStore.selectedSessionID = order[nextIndex]
    }

    /// Pane-scoped title only — no window fallback. The Workspace menu's
    /// close button calls `closeActivePane()`, which no-ops without a
    /// selection, so "Close Window" would be a lie on that surface.
    private var closePaneMenuTitle: String {
        (sessionStore.selectedSession?.layout.isSinglePane ?? false) ? "Close Workspace" : "Close Pane"
    }

    private var closeShortcutTitle: String {
        sessionStore.selectedSession == nil ? "Close Window" : closePaneMenuTitle
    }

    private var isAnySheetPresented: Bool {
        workspaceEditRequest != nil
            || paneEditRequest != nil
            || workspaceGroupCreateRequest != nil
            || remoteWorkspaceGroupCreateRequest != nil
            || sshWorkspaceConnectRequest != nil
            || workspaceGroupRenameRequest != nil
            || quickSettingsRequest != nil
            || ghosttyRuntime.isScrollbackDumpSheetPresented
    }

    private var floatingPanelMenuTitle: String {
        let base = floatingPanelController.isVisible ? "Hide Floating Panel" : "Show Floating Panel"
        guard floatingPanelController.hasBackgroundedRunningWork(for: sessionStore.selectedSession?.id) else {
            return base
        }
        return "\(base) (running)"
    }

    private var popUpTerminalMenuTitle: String {
        // Mirror toggle()'s actual behavior: it only minimizes when the panel
        // is expanded AND key; anything else (minimized, hidden-on-deactivate,
        // expanded-but-unfocused) re-presents it.
        let willMinimize = popUpTerminalController.isExpanded && popUpTerminalController.isPanelFocused
        return willMinimize ? "Minimize Terminal Companion" : "Show Terminal Companion"
    }

    private var commandPaletteMenuTitle: String {
        let action = commandPaletteController.isVisible ? "Hide" : "Show"
        return "\(action) Command Palette    \(shortcut(KeyboardShortcutCatalog.toggleCommandPalette).displaySymbol)"
    }

    private var sidebarVisibilityMenuTitle: String {
        SidebarVisibilityActionTitle.resolve(isHidden: isSidebarPersistentlyHidden)
    }

    private var keyboardCheatsheetMenuTitle: String {
        "Keyboard Shortcuts    \(shortcut(KeyboardShortcutCatalog.showKeyboardCheatsheet).displaySymbol)"
    }

    private func closeActivePaneOrWindow() {
        if sessionManagerController.hideIfKeyWindow() {
            return
        }

        if keyboardCheatsheetController.hideIfKeyWindow() {
            return
        }

        if commandPaletteController.hideIfKeyWindow() {
            return
        }

        let orderedWindows = NSApp.orderedWindows
        let popUpWindow = popUpTerminalController.ownedWindow
        let floatingWindow = floatingPanelController.ownedWindow
        let closeTarget = TerminalPanelCommandRouter.target(
            popUpIsKey: popUpWindow?.isKeyWindow == true,
            floatingIsKey: floatingWindow?.isKeyWindow == true,
            // Expanded, not `isVisible`: a minimized companion is a parked
            // corner tab, and letting it claim Cmd-W would swallow pane-close
            // app-wide while the tab sits in the corner.
            popUpIsVisible: popUpTerminalController.isExpanded,
            floatingIsVisible: floatingPanelController.isVisible,
            popUpOrder: popUpWindow.flatMap(orderedWindows.firstIndex),
            floatingOrder: floatingWindow.flatMap(orderedWindows.firstIndex)
        )
        if closeTarget == .popUp, popUpTerminalController.performCloseShortcut() {
            return
        }
        if closeTarget == .floating, floatingPanelController.hideIfVisible() {
            return
        }

        // No floating surface owns key. If a sheet is presented, Cmd-W is a
        // sheet-class action — swallow it rather than fall through to pane
        // destruction in a workspace behind the sheet the user can't see
        // (INT-269). Every other workspace command is already
        // `.disabled(isAnySheetPresented)`; Cmd-W routes through here instead
        // of a menu item, so it needs the guard explicitly.
        guard !isAnySheetPresented else { return }

        guard sessionStore.selectedSessionID != nil else {
            NSApp.keyWindow?.performClose(nil)
            return
        }
        closeActivePane()
    }

    @discardableResult
    private func splitActivePane(orientation: TerminalSplitOrientation) -> TerminalPane.ID? {
        guard let paneID = sessionStore.splitActivePane(orientation: orientation) else {
            return nil
        }

        announceSplit(orientation: orientation)
        return paneID
    }

    private func announceSplit(orientation: TerminalSplitOrientation) {
        let announcement: String
        switch orientation {
        case .vertical:
            announcement = String(
                localized: "Split pane right",
                comment: "VoiceOver announcement after creating a vertical split to the right of the active pane."
            )
        case .horizontal:
            announcement = String(
                localized: "Split pane down",
                comment: "VoiceOver announcement after creating a horizontal split below the active pane."
            )
        }
        postAccessibilityAnnouncement(announcement)
    }

    private func closeActivePane() {
        guard let sessionID = sessionStore.selectedSessionID else { return }

        ghosttyRuntime.refreshTerminalQuitConfirmationRisks(in: sessionStore)
        guard let session = sessionStore.session(id: sessionID) else { return }

        // Last pane = the workspace: route through the same soft-close funnel as
        // the sidebar X (confirm gate, floating-slot eviction, recently-closed
        // capture) instead of recycling the shell in place. ⇧⌘T reopens.
        // `alsoGateOnPaneActionConfirm: true` — this is still logically a pane
        // action (⌘W), so a user who only enabled the pane-confirm toggle
        // (not the workspace one) keeps that protection here too.
        if session.layout.isSinglePane {
            closeWorkspace(session, alsoGateOnPaneActionConfirm: true)
            return
        }

        let targetPaneID = session.activePaneID
        let action: DestructivePaneActionConfirmationPolicy.Action
        switch DestructivePaneActionConfirmationPolicy.decision(
            session: session,
            workspaces: appSettingsStore.workspaces.value
        ) {
        case .unavailable:
            return
        case let .proceedWithoutPrompt(resolvedAction):
            action = resolvedAction
        case let .prompt(resolvedAction):
            // `.prompt` is only ever returned when the policy already found
            // the active pane at risk (see `DestructivePaneActionConfirmationPolicy.decision`),
            // but recomputing here — rather than hardcoding `true` — keeps this
            // call site honest if that gate ever changes independently.
            let atRisk = session.activePane?.isCloseRisk(at: Date()) ?? false
            switch confirmDestructivePaneActionIfNeeded(resolvedAction, in: session, atRisk: atRisk) {
            case .suppressed:
                return
            case .userCancelled:
                announcePaneActionCancelled(resolvedAction)
                return
            case .proceed:
                action = resolvedAction
            }
        }

        switch action {
        case .restartShell:
            // Single-pane sessions route to closeWorkspace(_:) above before this
            // policy runs, so the pane policy never resolves .restartShell here.
            assertionFailure("single-pane routes to closeWorkspace before the pane policy")
        case .closePane:
            let refreshed = sessionStore.session(id: sessionID)
            switch DestructivePaneActionConfirmationPolicy.confirmedCloseAction(
                session: refreshed,
                targetPaneID: targetPaneID
            ) {
            case .alreadyClosed:
                return

            case .closeWorkspace:
                guard let refreshed else { return }
                closeWorkspace(refreshed, alsoGateOnPaneActionConfirm: false)
                return

            case .closePane:
                guard
                    case let .pane(closedPaneID) = sessionStore.closePane(
                        id: targetPaneID,
                        in: sessionID
                    )
                else { return }
                ghosttyRuntime.discardSurface(for: closedPaneID)
                announcePaneClosed()
            }
        }
    }

    /// Explicit "Restart Shell" command (command palette): recycles the
    /// active pane's shell in place. This is the ADR-0002 amendment's named
    /// replacement for the old single-pane ⌘W silent recycle — that trigger
    /// now closes the workspace instead (see `closeActivePane` above), so
    /// restarting a shell in place is only reachable as a deliberate,
    /// separately-confirmed command. Session-scoped, not pane-count-gated:
    /// `recycleAndAnnounce` replaces whichever pane is active, so this works
    /// the same for a single-pane or multi-pane session.
    ///
    /// ponytail: always confirms — no
    /// `DestructivePaneActionConfirmationPolicy` risk pre-check, unlike the
    /// routed ⌘W close-pane action. This is a deliberately-invoked command
    /// rather than a routed keystroke, so the unconditional prompt mirrors
    /// `clearWorkspace`'s "always confirm" precedent. Wire it through the
    /// policy's risk gate instead if the always-on prompt proves too naggy.
    /// The dialog COPY still branches on risk (see
    /// `confirmDestructivePaneActionIfNeeded`) — only the decision to show a
    /// prompt at all is unconditional.
    private func restartActiveShell() {
        guard let session = sessionStore.selectedSession else { return }
        ghosttyRuntime.refreshTerminalQuitConfirmationRisks(in: sessionStore)
        guard let refreshed = sessionStore.session(id: session.id) else { return }
        let atRisk = refreshed.activePane?.isCloseRisk(at: Date()) ?? false

        switch confirmDestructivePaneActionIfNeeded(.restartShell, in: refreshed, atRisk: atRisk) {
        case .suppressed:
            return
        case .userCancelled:
            announcePaneActionCancelled(.restartShell)
            return
        case .proceed:
            break
        }
        GhosttySurfaceNSView.recycleAndAnnounce(
            sessionID: refreshed.id,
            sessionStore: sessionStore,
            runtime: ghosttyRuntime
        )
    }

    private func announcePaneClosed() {
        let announcement = String(
            localized: "Pane closed",
            comment: "VoiceOver announcement after a pane is closed inside the active workspace (multi-pane case)."
        )
        postAccessibilityAnnouncement(announcement)
    }

    private func announcePaneActionCancelled(_ action: DestructivePaneActionConfirmationPolicy.Action) {
        let announcement: String
        switch action {
        case .restartShell:
            announcement = String(
                localized: "Restart shell cancelled",
                comment: "VoiceOver announcement after cancelling a restart-shell confirmation dialog."
            )
        case .closePane:
            announcement = String(
                localized: "Close pane cancelled",
                comment: "VoiceOver announcement after cancelling a close-pane confirmation dialog."
            )
        }
        postAccessibilityAnnouncement(announcement)
    }

    private func requestRenameSelectedWorkspace() {
        guard let session = sessionStore.selectedSession else {
            return
        }

        requestRenameWorkspace(session)
    }

    private func requestRenameWorkspace(_ session: TerminalSession) {
        guard !isAnySheetPresented else {
            return
        }

        workspaceEditRequest = WorkspaceEditRequest(
            id: session.id,
            title: session.title
        )
    }

    private func requestRenameActivePane() {
        guard !isAnySheetPresented,
            let session = sessionStore.selectedSession,
            session.layout.hasMultiplePanes,
            let pane = session.activePane
        else {
            return
        }
        paneEditRequest = PaneEditRequest(
            sessionID: session.id,
            paneID: pane.id,
            currentTitle: pane.title,
            isUserEdited: pane.isTitleUserEdited
        )
    }

    private func requestResetActivePaneTitle() {
        guard let session = sessionStore.selectedSession,
            session.layout.hasMultiplePanes,
            let pane = session.activePane,
            pane.isTitleUserEdited
        else {
            return
        }
        sessionStore.resetPaneTitle(sessionID: session.id, paneID: pane.id)
    }

    private func requestNewWorkspaceGroup() {
        guard !isAnySheetPresented else {
            return
        }

        workspaceGroupCreateRequest = WorkspaceGroupCreateRequest()
    }

    private func requestNewRemoteWorkspaceGroup() {
        guard !isAnySheetPresented else {
            return
        }

        remoteWorkspaceGroupCreateRequest = RemoteWorkspaceGroupCreateRequest()
    }

    private func requestConnectViaSSH(_ requestedGroup: SessionGroup? = nil) {
        guard !isAnySheetPresented else { return }
        let group =
            requestedGroup
            ?? SSHWorkspaceGroupTargeting.resolve(
                groups: sessionStore.groups,
                selectedSessionID: sessionStore.selectedSessionID,
                defaultGroupName: appSettingsStore.workspaces.value.defaultGroup
            )
        guard let group else { return }
        sshWorkspaceConnectRequest = SSHWorkspaceConnectRequest(
            initialDestination: nil,
            action: .addToGroup(id: group.id, name: group.name)
        )
    }

    private func requestManagedSSHWorkspaceOffer(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID
    ) {
        guard !isAnySheetPresented,
            let target = sessionStore.consumeManagedSSHWorkspaceOffer(
                sessionID: sessionID,
                paneID: paneID
            )
        else {
            return
        }
        sshWorkspaceConnectRequest = SSHWorkspaceConnectRequest(
            initialDestination: target.sshDestination,
            action: .convertPane(sessionID: sessionID, paneID: paneID)
        )
    }

    private func canMakeWorkspaceManaged(_ session: TerminalSession) -> Bool {
        guard !isAnySheetPresented,
            sessionStore.selectedSessionID == session.id
        else {
            return false
        }
        return sessionStore.managedSSHConversionTarget(
            sessionID: session.id,
            paneID: session.activePaneID
        ) != nil
    }

    private func requestManagedSSHWorkspaceConversion(_ session: TerminalSession? = nil) {
        guard !isAnySheetPresented,
            let request = SSHWorkspaceConnectRequest.managedConversion(
                sessionStore: sessionStore,
                sessionID: session?.id
            )
        else {
            return
        }
        sshWorkspaceConnectRequest = request
    }

    private func requestRenameWorkspaceGroup(_ group: SessionGroup) {
        guard !isAnySheetPresented else {
            return
        }

        workspaceGroupRenameRequest = WorkspaceGroupRenameRequest(
            id: group.id,
            name: group.name
        )
    }

    private func requestQuickSettings() {
        guard !isAnySheetPresented else {
            return
        }

        quickSettingsRequest = QuickSettingsRequest()
    }

    private func requestSidebarFocus() {
        sidebarCommandTargetAvailability.refresh()
        guard sidebarCommandTargetAvailability.isAvailable else {
            ShortcutDiagnostics.log("stage=requestSidebarFocus blocked=noPrimaryContentWindow")
            return
        }
        guard !isAnySheetPresented else {
            ShortcutDiagnostics.log("stage=requestSidebarFocus blocked=sheetPresented")
            return
        }

        appDelegate.surfacePrimaryWindow()
        ShortcutDiagnostics.log("stage=requestSidebarFocus action=emitRequest")
        sidebarPresentationCommandMailbox.requestFocus()
    }

    private func requestSidebarWidthToggle() {
        sidebarCommandTargetAvailability.refresh()
        guard sidebarCommandTargetAvailability.isAvailable else {
            ShortcutDiagnostics.log("stage=requestSidebarWidthToggle blocked=noPrimaryContentWindow")
            return
        }
        guard !isAnySheetPresented else {
            ShortcutDiagnostics.log("stage=requestSidebarWidthToggle blocked=sheetPresented")
            return
        }

        ShortcutDiagnostics.log("stage=requestSidebarWidthToggle action=emitRequest")
        sidebarWidthToggleRequestID = UUID()
    }

    private func requestSidebarVisibilityToggle() {
        sidebarCommandTargetAvailability.refresh()
        guard sidebarCommandTargetAvailability.isAvailable else {
            ShortcutDiagnostics.log(
                "stage=requestSidebarVisibilityToggle blocked=noPrimaryContentWindow")
            return
        }
        guard !isAnySheetPresented else {
            ShortcutDiagnostics.log("stage=requestSidebarVisibilityToggle blocked=sheetPresented")
            return
        }
        ShortcutDiagnostics.log("stage=requestSidebarVisibilityToggle action=emitRequest")
        sidebarPresentationCommandMailbox.requestVisibilityToggle(
            currentIsHidden: isSidebarPersistentlyHidden)
    }

    private func toggleFloatingPanel() {
        // The menu item disables on sheet-present, but the keyboard shortcut
        // still fires through SwiftUI's command system; guard here too.
        guard !isAnySheetPresented else { return }
        floatingPanelController.toggle(
            relativeTo: NSApp.mainWindow ?? NSApp.keyWindow,
            sessionStore: sessionStore,
            ghosttyRuntime: ghosttyRuntime,
            appSettingsStore: appSettingsStore
        )
    }

    private func togglePopUpTerminal() {
        guard !isAnySheetPresented else { return }
        popUpTerminalController.toggle(
            relativeTo: NSApp.awesoMuxPrimaryContentWindow,
            sessionStore: sessionStore,
            ghosttyRuntime: ghosttyRuntime,
            appSettingsStore: appSettingsStore
        )
    }

    private func toggleCommandPalette() {
        guard !isAnySheetPresented else { return }
        commandPaletteController.toggle(
            relativeTo: NSApp.mainWindow ?? NSApp.keyWindow,
            presenter: makeCommandPalettePresenter()
        )
    }

    private func showKeyboardCheatsheet() {
        guard !isAnySheetPresented else { return }
        keyboardCheatsheetController.show(
            relativeTo: NSApp.mainWindow ?? NSApp.keyWindow,
            canRunShortcut: canRunKeyboardCheatsheetShortcut,
            runShortcut: runKeyboardCheatsheetShortcut
        )
    }

    private func toggleKeyboardCheatsheet() {
        guard !isAnySheetPresented else { return }
        keyboardCheatsheetController.toggle(
            relativeTo: NSApp.mainWindow ?? NSApp.keyWindow,
            canRunShortcut: canRunKeyboardCheatsheetShortcut,
            runShortcut: runKeyboardCheatsheetShortcut
        )
    }

    private func toggleSessionManager() {
        guard !isAnySheetPresented else { return }
        sessionManagerController.toggle(
            model: sessionManagerModel,
            relativeTo: NSApp.mainWindow ?? NSApp.keyWindow,
            onJump: jumpToDaemonOwner
        )
    }

    private var worktreeRepositorySelectionID: String? {
        guard let session = sessionStore.selectedSession,
            let pane = session.activePane,
            WorkspacePaneCapabilities.terminal(pane).localFileAccess
        else {
            return nil
        }
        return "\(session.id.uuidString)|\(pane.id.uuidString)|\(pane.workingDirectory)"
    }

    private func refreshWorktreeRepositoryContext() async {
        // While the manager is open, its own operations (list/create) already
        // re-validate repository identity and fail closed on drift. Swapping
        // `worktreeManagerModel` out from under a VISIBLE panel here would
        // orphan the hosted view on the old model (the controller only
        // rehosts on the next explicit `show()`) and could race an in-flight
        // Create on that old model — simplest correct fix is to not do it.
        guard !worktreeManagerController.isVisible else { return }
        guard let selectionID = worktreeRepositorySelectionID,
            let pane = sessionStore.selectedSession?.activePane
        else {
            worktreeManagerModel = nil
            worktreeManagerController.dismiss()
            return
        }

        let outcome = await LocalGitRepositoryLocator().locate(
            startingAt: URL(fileURLWithPath: pane.workingDirectory)
        )
        guard selectionID == worktreeRepositorySelectionID,
            case .located(let context) = outcome
        else {
            if selectionID == worktreeRepositorySelectionID {
                worktreeManagerModel = nil
                worktreeManagerController.dismiss()
            }
            return
        }
        worktreeManagerModel = WorktreeManagerModel(
            repositoryContext: context,
            sessionStore: sessionStore
        )
    }

    private func toggleWorktreeManager() {
        guard !isAnySheetPresented, let worktreeManagerModel else { return }
        worktreeManagerController.toggle(
            model: worktreeManagerModel,
            relativeTo: NSApp.mainWindow ?? NSApp.keyWindow
        )
    }

    private func presentFindInActivePane() {
        guard !isAnySheetPresented,
            let session = sessionStore.selectedSession
        else {
            return
        }
        _ = ghosttyRuntime.presentSearch(in: session.activePaneID)
    }

    private func presentScrollbackDumpForActivePane() {
        guard !isAnySheetPresented,
            let session = sessionStore.selectedSession
        else {
            return
        }
        _ = ghosttyRuntime.presentScrollbackDump(in: session.activePaneID)
    }

    /// Keyboard/VoiceOver route to the disconnected pane's reconnect button
    /// (INT-697 fix #3b). The enactor's own `beginManualReconnect` guard no-ops
    /// unless the active pane is actually showing the disconnected overlay.
    private func reconnectActiveRemotePane() {
        guard let session = sessionStore.selectedSession else {
            return
        }
        _ = ghosttyRuntime.reconnectRemotePane(in: session.activePaneID)
    }

    /// Selects the workspace that owns a daemon (reusing the same selection +
    /// terminal-focus path the command palette uses) so "Jump" lands the user on
    /// the live pane. Session-level by design — the model resolves a daemon to its
    /// owning session, and we focus that session's active pane.
    private func jumpToDaemonOwner(_ id: TerminalSessionID) {
        guard let target = sessionManagerModel.jumpTarget(for: id),
            let session = sessionStore.session(id: target.sessionID)
        else {
            return
        }
        sessionStore.selectedSessionID = target.sessionID
        appDelegate.surfacePrimaryWindow()
        requestTerminalFocus(sessionID: target.sessionID, paneID: session.activePaneID)
    }

    private func makeCommandPalettePresenter() -> PalettePresenter {
        PalettePresenter(
            sessionGroups: sessionStore.groups,
            commands: currentPaletteCommands(),
            selectSession: { sessionID in
                guard let session = sessionStore.session(id: sessionID) else {
                    return false
                }
                sessionStore.selectedSessionID = sessionID
                appDelegate.surfacePrimaryWindow()
                requestTerminalFocus(sessionID: sessionID, paneID: session.activePaneID)
                return true
            },
            runCommand: { commandID in
                runPaletteCommand(id: commandID)
            },
            runQuickRun: { quickRun, surface in
                runQuickRun(quickRun, surface: surface)
            }
        )
    }

    private func runPaletteCommand(id commandID: PaletteCommand.ID) -> Bool {
        let commands = currentPaletteCommands()
        guard let command = PaletteCommandRegistry.command(id: commandID, in: commands),
            command.isEnabled
        else {
            // A custom command deleted between palette-open and Enter is
            // absent from the freshly rebuilt list, so it lands here instead
            // of reaching `runCustomCommand`'s stale-id guard. Route it there
            // so the "no longer exists" feedback actually fires.
            if let customCommandID = PaletteCommand.customCommandUUID(fromID: commandID) {
                runCustomCommand(id: customCommandID)
                return true
            }
            // A recently-closed entry drained between palette-open and Enter
            // (reopened from another surface, or TTL-expired) is absent from
            // the rebuilt list. The palette has already dismissed by now, so
            // without this the miss is totally silent — match the menu/Dock
            // paths' stale-entry beep (INT-282).
            if commandID.hasPrefix(PaletteCommandRegistry.reopenRecentIDPrefix) {
                signalReopenEntryUnavailable()
                return true
            }
            return false
        }
        command.run()
        return true
    }

    private func canRunKeyboardCheatsheetShortcut(id commandID: KeyboardShortcutEntry.ID) -> Bool {
        let commands = currentPaletteCommands()
        guard let command = PaletteCommandRegistry.command(id: commandID, in: commands) else {
            return false
        }
        return command.isEnabled
    }

    private func runKeyboardCheatsheetShortcut(id commandID: KeyboardShortcutEntry.ID) -> Bool {
        runPaletteCommand(id: commandID)
    }

    private func runQuickRun(
        _ quickRun: PaletteQuickRunResult,
        surface: PaletteQuickRunCommitSurface
    ) -> Bool {
        switch surface {
        case .toast:
            runQuickRunToast(quickRun)
        case .floatingPanel:
            runQuickRunInFloatingPanel(quickRun)
        case .newTab:
            runQuickRunInNewTab(quickRun)
        }
        return true
    }

    private func runQuickRunToast(_ quickRun: PaletteQuickRunResult) {
        let toastID = UUID()
        quickRunToast = QuickRunToast(
            id: toastID,
            command: quickRun.command,
            output: "",
            state: .running
        )
        announceQuickRun("Running \(quickRun.command).")

        Task {
            let runner = ProcessCommandRunner(timeout: .seconds(15))
            do {
                let result = try await runner.run(
                    executable: "/bin/zsh",
                    args: ["-fc", quickRun.command],
                    env: ["PATH": ProcessCommandRunner.defaultToolPath],
                    cwd: selectedWorkingDirectoryURL()
                )
                await MainActor.run {
                    let output = Self.quickRunToastOutput(stdout: result.stdout, stderr: result.stderr)
                    quickRunToast = QuickRunToast(
                        id: toastID,
                        command: quickRun.command,
                        output: output,
                        state: .finished(exitCode: result.exitCode)
                    )
                    announceQuickRun("Quick run finished with exit code \(result.exitCode). \(output)")
                    scheduleQuickRunToastDismissal(id: toastID)
                }
            } catch {
                await MainActor.run {
                    let message = error.localizedDescription
                    quickRunToast = QuickRunToast(
                        id: toastID,
                        command: quickRun.command,
                        output: message,
                        state: .failed(message)
                    )
                    announceQuickRun("Quick run failed. \(message)")
                    scheduleQuickRunToastDismissal(id: toastID)
                }
            }
        }
    }

    private func runQuickRunInFloatingPanel(_ quickRun: PaletteQuickRunResult) {
        let workspaceID = sessionStore.selectedSession?.id
        floatingPanelController.show(
            relativeTo: NSApp.mainWindow ?? NSApp.keyWindow,
            sessionStore: sessionStore,
            ghosttyRuntime: ghosttyRuntime,
            appSettingsStore: appSettingsStore,
            announcement: .concise
        )
        guard let paneID = floatingPanelController.activeFloatingPaneID(for: workspaceID) else {
            announceQuickRun("Could not run \(quickRun.command) in the floating panel.")
            return
        }
        sendQuickRunCommand(quickRun.command, toPane: paneID)
    }

    private func runQuickRunInNewTab(_ quickRun: PaletteQuickRunResult) {
        // QuickRun keeps its historical shape: tab titled with the command
        // text itself, unpinned so Ghostty's live title sync takes over.
        runCommandInNewTab(
            command: quickRun.command,
            tabTitle: quickRun.command,
            pinsTitle: false
        )
    }

    /// Opens a new tab titled `tabTitle` and sends `command` through the
    /// QuickRun retry path. `pinsTitle` marks the title user-edited (the
    /// `renameSession` pin) so Ghostty's live title sync can't overwrite a
    /// custom command's name; `addSession(title:)` alone leaves it unpinned.
    private func runCommandInNewTab(
        command: String,
        tabTitle: String,
        pinsTitle: Bool
    ) {
        let sessionID = sessionStore.addSession(
            title: tabTitle,
            workingDirectory: sessionStore.selectedSession?.workingDirectory,
            groupName: appSettingsStore.workspaces.value.defaultGroup
        )
        guard let session = sessionStore.session(id: sessionID) else {
            announceQuickRun(
                String(
                    localized: "Could not create a new tab for \(command).",
                    comment: "Accessibility announcement when opening a new tab for a palette command fails"
                ))
            return
        }
        if pinsTitle {
            sessionStore.renameSession(id: sessionID, title: tabTitle)
        }
        appDelegate.surfacePrimaryWindow()
        requestTerminalFocus(sessionID: sessionID, paneID: session.activePaneID)
        sendQuickRunCommand(command, toPane: session.activePaneID)
    }

    /// Run closure target for custom-command palette entries. Re-resolves by
    /// id at run time so an edit or delete between palette-open and Enter is
    /// self-healing instead of running stale captured text.
    private func runCustomCommand(id: UUID) {
        guard let customCommand = customCommandStore.command(id: id) else {
            let message = String(
                localized: "That custom command no longer exists.",
                comment: "Feedback when a palette custom command was deleted before it ran"
            )
            // Toast so sighted users get the same feedback as the VO
            // announcement — nothing else visible happens on this path.
            let toastID = UUID()
            quickRunToast = QuickRunToast(
                id: toastID,
                command: String(
                    localized: "Custom command",
                    comment: "Toast headline placeholder when the deleted custom command's text is unknown"
                ),
                output: message,
                state: .failed(message)
            )
            scheduleQuickRunToastDismissal(id: toastID)
            announceQuickRun(message)
            return
        }
        runCommandInNewTab(
            command: customCommand.command,
            tabTitle: customCommand.name,
            pinsTitle: true
        )
    }

    private func sendQuickRunCommand(
        _ command: String,
        toPane paneID: TerminalPane.ID,
        attempt: Int = 0
    ) {
        if ghosttyRuntime.sendText(command + "\n", toPane: paneID) {
            announceQuickRun("Running \(command).")
            return
        }

        guard attempt < 12 else {
            announceQuickRun("Could not send \(command). The terminal surface was not ready.")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            sendQuickRunCommand(command, toPane: paneID, attempt: attempt + 1)
        }
    }

    private func scheduleQuickRunToastDismissal(id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if quickRunToast?.id == id {
                quickRunToast = nil
            }
        }
    }

    private func selectedWorkingDirectoryURL() -> URL? {
        guard let workingDirectory = sessionStore.selectedSession?.workingDirectory,
            !workingDirectory.isEmpty,
            let validated = WorkingDirectoryValidator.validatedStartupDirectory(workingDirectory)
        else {
            return nil
        }
        return URL(fileURLWithPath: validated, isDirectory: true)
    }

    private func announceQuickRun(_ message: String) {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow else { return }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    private static func quickRunToastOutput(stdout: String, stderr: String) -> String {
        let combined = [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard combined.count > 280 else { return combined }
        let prefix = combined.prefix(280)
        return String(prefix) + "..."
    }

    private func currentPaletteCommands() -> [PaletteCommand] {
        sidebarCommandTargetAvailability.refresh()
        var commands = PaletteCommandRegistry.commands(
            sessionStore: sessionStore,
            availability: PaletteCommandAvailability(
                isAnySheetPresented: isAnySheetPresented,
                isOpenInIDEEnabled: appSettingsStore.workspaces.value.openInIDEEnabled,
                isSidebarHidden: isSidebarPersistentlyHidden,
                isSidebarCommandTargetAvailable: sidebarCommandTargetAvailability.isAvailable,
                isWorktreeManagerAvailable: worktreeManagerModel != nil && !isAnySheetPresented
            ),
            actions: paletteActions,
            keyboard: keyboardConfig
        )
        // One jump command per owned or detachedRestorable daemon — the only two
        // lifecycles that have a reachable workspace pane to land on. The daemon
        // rows are snapshotted from the model at palette-open time (matching the
        // existing pattern for sessionGroups), so the list reflects the state
        // when the palette was summoned rather than trying to live-update.
        for row in sessionManagerModel.rows
        where row.lifecycle == .owned || row.lifecycle == .detachedRestorable {
            let daemonID = row.id
            let label = row.owner ?? row.id.rawValue
            commands.append(
                PaletteCommand(
                    id: "daemonJump.\(row.id.rawValue)",
                    title: "Jump to Session: \(label)",
                    subtitle: "Background session",
                    keywords: ["session", "daemon", "jump", "bridge", "background"],
                    shortcut: nil,
                    isEnabled: true,
                    run: { [self] in
                        jumpToDaemonOwner(daemonID)
                    }
                ))
        }
        for customCommand in customCommandStore.commands {
            let commandID = customCommand.id
            commands.append(
                .customCommand(
                    customCommand,
                    run: { [self] in
                        runCustomCommand(id: commandID)
                    }))
        }
        return commands
    }

    private var paletteActions: PaletteAppActions {
        PaletteAppActions(
            newWorkspace: {
                sessionStore.addSession(
                    groupName: appSettingsStore.workspaces.value.defaultGroup
                )
                appDelegate.surfacePrimaryWindow()
            },
            newWorkspaceInCurrentDirectory: {
                sessionStore.addSession(
                    workingDirectory: sessionStore.selectedSession?.workingDirectory
                )
                appDelegate.surfacePrimaryWindow()
            },
            newWorkspaceGroup: requestNewWorkspaceGroup,
            newRemoteWorkspaceGroup: requestNewRemoteWorkspaceGroup,
            connectViaSSH: { requestConnectViaSSH() },
            makeThisWorkspaceManaged: { requestManagedSSHWorkspaceConversion() },
            renameWorkspace: requestRenameSelectedWorkspace,
            renamePane: requestRenameActivePane,
            resetPaneTitle: requestResetActivePaneTitle,
            closeWorkspace: closeSelectedSession,
            clearWorkspace: clearSelectedSession,
            reopenClosedWorkspace: reopenMostRecentlyClosedWorkspace,
            reopenRecent: reopenRecentWorkspace,
            splitRight: {
                splitActivePane(orientation: .vertical)
            },
            splitDown: {
                splitActivePane(orientation: .horizontal)
            },
            closePane: closeActivePane,
            restartShell: restartActiveShell,
            find: presentFindInActivePane,
            scrollbackDump: presentScrollbackDumpForActivePane,
            reconnectRemotePane: reconnectActiveRemotePane,
            growActivePane: {
                sessionStore.resizeActiveSplit(by: 0.05)
            },
            shrinkActivePane: {
                sessionStore.resizeActiveSplit(by: -0.05)
            },
            previousPane: {
                sessionStore.focusPane(.previous)
                announceActivePaneFocused()
            },
            nextPane: {
                sessionStore.focusPane(.next)
                announceActivePaneFocused()
            },
            previousDocumentTab: {
                selectAdjacentDocumentTab(offset: -1)
            },
            nextDocumentTab: {
                selectAdjacentDocumentTab(offset: 1)
            },
            closeDocumentTab: closeSelectedDocumentTab,
            movePaneUp: {
                moveActivePane(toWorkspaceEdge: .up)
            },
            movePaneDown: {
                moveActivePane(toWorkspaceEdge: .down)
            },
            movePaneLeft: {
                moveActivePane(toWorkspaceEdge: .left)
            },
            movePaneRight: {
                moveActivePane(toWorkspaceEdge: .right)
            },
            swapPaneWithNext: swapActivePaneWithNext,
            focusPane: { paneIndex in
                if sessionStore.focusPane(at: paneIndex) {
                    announcePaneFocused(index: paneIndex)
                }
            },
            acknowledgeWorkspace: {
                if let id = sessionStore.selectedSessionID {
                    // Workspace-scoped like the menu item and banner button
                    // that share this command's name — the active-pane-only
                    // ack silently no-ops when attention sits on a sibling
                    // pane in a split.
                    sessionStore.acknowledgeAllPanes(in: id)
                }
            },
            focusPermissionPrompt: {
                guard let sessionID = sessionStore.selectedSessionID,
                    let session = sessionStore.session(id: sessionID)
                else {
                    return
                }
                let candidates =
                    [session.activePaneID]
                    + session.layout.paneIDs.filter { $0 != session.activePaneID }
                guard
                    let target = candidates.lazy.compactMap({ paneID -> (TerminalPane.ID, BridgePermissionCoordinator)? in
                        guard let terminalSessionID = session.layout.pane(id: paneID)?.terminalSessionID,
                            let coordinator = ghosttyRuntime.bridgeCoordinatorStore.coordinator(for: terminalSessionID),
                            coordinator.activePrompt != nil
                        else {
                            return nil
                        }
                        return (paneID, coordinator)
                    }).first
                else {
                    return
                }
                sessionStore.setActivePane(id: target.0, in: sessionID)
                // Mount the newly selected pane's banner before changing its
                // focus token; otherwise an inactive sibling would miss the
                // onChange edge during the same render transaction.
                DispatchQueue.main.async { target.1.requestFocus() }
            },
            clearAllNotifications: {
                sessionStore.acknowledgeAllSessions()
            },
            toggleFloatingPanel: toggleFloatingPanel,
            togglePopUpTerminal: togglePopUpTerminal,
            toggleCommandPalette: toggleCommandPalette,
            focusSidebar: requestSidebarFocus,
            toggleSidebarWidth: requestSidebarWidthToggle,
            toggleSidebarVisibility: requestSidebarVisibilityToggle,
            jumpWorkspace: { index in
                selectWorkspace(atFlatIndex: index)
                if sessionStore.selectedSessionID != nil {
                    appDelegate.surfacePrimaryWindow()
                }
            },
            previousWorkspace: {
                selectWorkspaceRelative(offset: -1)
                if sessionStore.selectedSessionID != nil {
                    appDelegate.surfacePrimaryWindow()
                }
            },
            nextWorkspace: {
                selectWorkspaceRelative(offset: 1)
                if sessionStore.selectedSessionID != nil {
                    appDelegate.surfacePrimaryWindow()
                }
            },
            togglePinWorkspace: {
                guard let id = sessionStore.selectedSessionID else { return }
                sessionStore.togglePin(sessionID: id)
            },
            recenterPalette: {
                commandPaletteController.recenter()
            },
            openSettings: openSettingsWindow,
            openInIDE: openSelectedWorkspaceInIDE,
            showKeyboardCheatsheet: toggleKeyboardCheatsheet,
            openMarkdownFile: openMarkdownFilePanel,
            openSessionManager: toggleSessionManager,
            openWorktreeManager: toggleWorktreeManager,
            createWorktree: toggleWorktreeManager,
            openWorktree: toggleWorktreeManager
        )
    }

    private func openSelectedWorkspaceInIDE() {
        openSelectedWorkspaceInIDE(with: nil)
    }

    private func openSelectedWorkspaceInIDE(with selectedIDE: InstalledIDE?) {
        guard appSettingsStore.workspaces.value.openInIDEEnabled,
            !isAnySheetPresented,
            let session = sessionStore.selectedSession,
            IDEOpenTarget.isEligible(session: session)
        else {
            return
        }

        Task {
            guard let targetURL = await IDEOpenTarget.resolve(session: session) else {
                showIDEOpenTargetUnavailableAlert()
                return
            }
            if let selectedIDE {
                // An explicit titlebar/menu pick is a one-off; it does not
                // rewrite the saved priority. The default is set in Settings.
                open(targetURL, with: selectedIDE)
                return
            }
            openURLInIDE(targetURL)
        }
    }

    private func openURLInIDE(_ targetURL: URL) {
        Task {
            let installed = await installedIDEs()
            openURLInIDE(targetURL, installed: installed)
        }
    }

    private func installedIDEs() async -> [InstalledIDE] {
        let extraBundleIdentifiers = appSettingsStore.workspaces.value.defaultIDEPriority
        return await Task.detached(priority: .utility) {
            InstalledIDEDiscovery.installed(
                extraBundleIdentifiers: extraBundleIdentifiers,
                resolveApplicationURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
                displayName: InstalledIDEDiscovery.bundleDisplayName
            )
        }.value
    }

    private func openURLInIDE(_ targetURL: URL, installed: [InstalledIDE]) {
        guard !installed.isEmpty else {
            showNoIDEsFoundAlert()
            return
        }

        let ordered = IDEChoice.ordered(
            installed: installed,
            priority: appSettingsStore.workspaces.value.defaultIDEPriority
        )
        let ide: InstalledIDE?
        switch IDEChoice.nextStep(ordered: ordered) {
        case .unavailable:
            showNoIDEsFoundAlert()
            return
        case .open(let installedIDE):
            ide = installedIDE
        case .choose(let preselectedBundleIdentifier):
            ide = chooseIDE(
                from: ordered,
                preselectedBundleIdentifier: preselectedBundleIdentifier
            )
        }
        guard let ide else {
            return
        }

        open(targetURL, with: ide)
    }

    private func chooseIDE(
        from installed: [InstalledIDE],
        preselectedBundleIdentifier: String?
    ) -> InstalledIDE? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Open in IDE", comment: "IDE picker alert title.")
        alert.informativeText = String(localized: "Choose an IDE for this project.", comment: "IDE picker alert explanatory text.")
        alert.alertStyle = .informational

        let popup = NSPopUpButton(
            frame: NSRect(x: 0, y: 0, width: 320, height: 26),
            pullsDown: false
        )
        popup.setAccessibilityLabel(String(localized: "IDE", comment: "Accessibility label for the IDE picker popup."))
        popup.setAccessibilityHelp(
            String(localized: "Choose the IDE or editor to open this project.", comment: "Accessibility help for the IDE picker popup."))
        for ide in installed {
            popup.addItem(withTitle: ide.displayName)
        }
        if let preselectedBundleIdentifier,
            let savedIndex = installed.firstIndex(where: { $0.bundleIdentifier == preselectedBundleIdentifier })
        {
            popup.selectItem(at: savedIndex)
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: String(localized: "Open", comment: "Button title that opens the selected IDE."))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Button title that cancels choosing an IDE."))

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        let selectedIndex = popup.indexOfSelectedItem
        guard installed.indices.contains(selectedIndex) else {
            return nil
        }
        return installed[selectedIndex]
    }

    private func open(_ targetURL: URL, with ide: InstalledIDE) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [targetURL],
            withApplicationAt: ide.applicationURL,
            configuration: configuration
        ) { _, error in
            guard let error else {
                return
            }
            let message = error.localizedDescription
            Task { @MainActor in
                Self.showIDEOpenFailureAlert(
                    ideName: ide.displayName,
                    targetURL: targetURL,
                    message: message
                )
            }
        }
    }

    private func showIDEOpenTargetUnavailableAlert() {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Could Not Resolve Project Folder",
            comment: "Alert title shown when awesoMux cannot resolve a local folder for Open in IDE.")
        alert.informativeText = String(
            localized: "awesoMux could not find a local folder to open for the active pane.",
            comment: "Alert text shown when Open in IDE cannot resolve a target folder.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK", comment: "Button title that dismisses an alert."))
        alert.runModal()
    }

    private func showNoIDEsFoundAlert() {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "No Supported IDEs Found", comment: "Alert title shown when Open in IDE cannot find an installed supported IDE.")
        alert.informativeText = String(
            localized: "Install a supported Mac IDE or editor, then try again.",
            comment: "Alert text shown when no supported IDE is installed.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK", comment: "Button title that dismisses an alert."))
        alert.runModal()
    }

    private static func showIDEOpenFailureAlert(
        ideName: String,
        targetURL: URL,
        message: String
    ) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Could Not Open in \(ideName)", comment: "Alert title shown when opening a project in the selected IDE fails.")
        alert.informativeText = "\(targetURL.path)\n\n\(message)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK", comment: "Button title that dismisses an alert."))
        alert.runModal()
    }

    private func openMarkdownFilePanel() {
        guard sessionStore.selectedSession != nil else {
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md"),
            UTType(filenameExtension: "markdown"),
        ].compactMap { $0 }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = selectedMarkdownOpenDirectoryURL()

        guard panel.runModal() == .OK, let url = panel.url else { return }

        _ = sessionStore.openDocumentPane(fileURL: url)
    }

    private func selectedMarkdownOpenDirectoryURL() -> URL? {
        guard let selectedSession = sessionStore.selectedSession else {
            return nil
        }

        let validated = WorkingDirectoryValidator.firstValidatedReportedDirectory(from: [
            selectedSession.activePane?.workingDirectory,
            selectedSession.workingDirectory,
        ])
        return validated.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func openSettingsWindow() {
        guard let openWindowAction else {
            assertionFailure("Open Settings requested before openWindow action was captured.")
            NSSound.beep()
            return
        }

        openWindowAction(id: AwesoMuxSceneID.settings)
    }

    private func openPrimaryWindow() {
        guard let openWindowAction else {
            assertionFailure("Open primary window requested before openWindow action was captured.")
            NSSound.beep()
            return
        }

        // `Window(id:)` is singleton by id, so rapid Dock actions may safely ask
        // SwiftUI to open the same primary scene while the first request mounts.
        openWindowAction(id: AwesoMuxSceneID.primary)
    }

    /// Reads `openWindow` from the window's environment (only available inside
    /// a view) and stashes it where the App-level palette wiring can reach it.
    private struct CaptureOpenWindowAction: ViewModifier {
        @Environment(\.openWindow) private var openWindow
        @Binding var action: OpenWindowAction?

        func body(content: Content) -> some View {
            content.onAppear { action = openWindow }
        }
    }

    private struct SettingsCommands: Commands {
        @Environment(\.openWindow) private var openWindow

        var body: some Commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    openWindow(id: AwesoMuxSceneID.settings)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    private struct NewWorkspaceCommands: Commands {
        @Environment(\.openWindow) private var openWindow
        let sessionStore: SessionStore
        let appSettingsStore: AppSettingsStore
        let shortcut: KeyBinding

        var body: some Commands {
            CommandGroup(replacing: .newItem) {
                Button("New Workspace") {
                    // Honor `workspaces.default_group` for cold-start
                    // / menu-driven creation — previously this used
                    // `addSession()`'s hard-coded "awesoMux" default,
                    // so the configured default group was silently
                    // ignored unless the user happened to have an
                    // existing session selected (which routes through
                    // its owner group).
                    sessionStore.addSession(
                        groupName: appSettingsStore.workspaces.value.defaultGroup
                    )
                    openWindow(id: AwesoMuxSceneID.primary)
                }
                .keyboardShortcut(shortcut)
            }
        }
    }

    private func requestTerminalFocus(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID
    ) {
        DispatchQueue.main.async {
            guard let window = NSApp.awesoMuxPrimaryContentWindow else {
                return
            }
            guard
                let surface = PrimaryContentFocusRouter.terminalSurface(
                    in: window.contentView,
                    sessionID: sessionID,
                    paneID: paneID
                )
            else {
                window.makeFirstResponder(nil)
                return
            }
            window.makeFirstResponder(surface)
        }
    }

    private func focusActiveTerminal(
        _ request: SidebarFocusHandoffRequest
    ) -> SidebarFocusHandoffOutcome? {
        PrimaryContentFocusRouter.focus(
            request,
            sessionStore: sessionStore,
            application: NSApp)
    }

    private func dismissWorkspaceEditorIfTargetClosed() {
        guard let workspaceEditRequest,
            !sessionStore.groups.contains(where: { group in
                group.sessions.contains { $0.id == workspaceEditRequest.id }
            })
        else {
            return
        }

        self.workspaceEditRequest = nil
    }

    private func dismissPaneEditorIfTargetClosed() {
        guard let paneEditRequest else {
            return
        }
        // If the pane (or its session) exited/closed while the sheet was open,
        // Save/Reset would silently target a dead id — dismiss instead (Codex).
        let targetExists =
            sessionStore.session(id: paneEditRequest.sessionID)?
            .layout.pane(id: paneEditRequest.paneID) != nil
        if !targetExists {
            self.paneEditRequest = nil
        }
    }

    private func dismissWorkspaceGroupEditorIfTargetClosed() {
        guard let workspaceGroupRenameRequest,
            !sessionStore.groups.contains(where: { $0.id == workspaceGroupRenameRequest.id })
        else {
            return
        }

        self.workspaceGroupRenameRequest = nil
    }

}

private struct WorkspaceEditRequest: Identifiable, Sendable {
    let id: TerminalSession.ID
    let title: String
}

private struct PaneEditRequest: Identifiable, Sendable {
    let id = UUID()
    let sessionID: TerminalSession.ID
    let paneID: TerminalPane.ID
    let currentTitle: String
    let isUserEdited: Bool
}

private struct WorkspaceGroupCreateRequest: Identifiable, Sendable {
    let id = UUID()
}

private struct RemoteWorkspaceGroupCreateRequest: Identifiable, Sendable {
    let id = UUID()
}

struct SSHWorkspaceConnectRequest: Identifiable, Sendable {
    let id = UUID()
    let initialDestination: String?
    let action: SSHWorkspaceConnectAction

    @MainActor
    static func managedConversion(
        sessionStore: SessionStore,
        sessionID: TerminalSession.ID? = nil
    ) -> Self? {
        let session =
            if let sessionID {
                sessionStore.session(id: sessionID)
            } else {
                sessionStore.selectedSession
            }
        guard let session,
            sessionStore.selectedSessionID == session.id,
            let target = sessionStore.managedSSHConversionTarget(
                sessionID: session.id,
                paneID: session.activePaneID
            )
        else {
            return nil
        }
        return Self(
            initialDestination: target.sshDestination,
            action: .convertPane(sessionID: session.id, paneID: session.activePaneID)
        )
    }
}

enum SSHWorkspaceConnectAction: Sendable {
    case addToGroup(id: SessionGroup.ID, name: String)
    case convertPane(sessionID: TerminalSession.ID, paneID: TerminalPane.ID)

    var groupName: String? {
        switch self {
        case .addToGroup(_, let name): name
        case .convertPane: nil
        }
    }
}

private struct WorkspaceGroupRenameRequest: Identifiable, Sendable {
    let id: SessionGroup.ID
    let name: String
}

private struct QuickSettingsRequest: Identifiable, Sendable {
    let id = UUID()
}

extension AwesoMuxApp {
    /// Persist the session store, gated on `general.restoreWorkspaces`.
    /// When restore is disabled the user has opted out of session
    /// persistence — saving a fresh, empty store on every onAppear /
    /// onChange would clobber the previous session-state.json and make
    /// re-enabling restore unable to recover the prior state.
    private func saveSessionIfRestoreEnabled() {
        guard appSettingsStore.general.value.restoreWorkspaces else { return }
        SessionPersistence.save(sessionStore)
    }

    private func presentRecoveryWarningIfNeeded() {
        guard let warning = recoveryWarning, !didPresentRecoveryWarning else {
            return
        }

        didPresentRecoveryWarning = true

        switch warning.kind {
        case .archivedSnapshot:
            presentArchiveRecoveryWarning(warning)
        case .sanitizedRestore:
            presentSanitizedRestoreWarning(warning)
        }
    }

    private func presentArchiveRecoveryWarning(
        _ warning: SessionPersistence.SessionRecoveryWarning
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't reopen your last workspaces"
        alert.informativeText =
            "We couldn't read your saved workspace data, so awesoMux opened with fresh workspaces. Your old data is saved as a file in case you want to recover it later."

        alert.accessoryView = recoveryPathAccessoryField(for: warning)

        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Copy Path")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].isEnabled = warning.archivedSnapshotURL != nil
        alert.buttons[2].isEnabled = warning.archivedSnapshotURL != nil

        switch alert.runModal() {
        case .alertSecondButtonReturn:
            if let url = warning.archivedSnapshotURL,
                isSafeRecoveryArchiveURL(url)
            {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .alertThirdButtonReturn:
            if let path = warning.archivedSnapshotURL?.path {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        default:
            break
        }
    }

    private func presentSanitizedRestoreWarning(
        _ warning: SessionPersistence.SessionRecoveryWarning
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some workspace data was adjusted"
        var informativeLines = [
            "awesoMux reopened your saved workspaces, but cleaned up data that could not be restored safely."
        ]
        informativeLines.append(contentsOf: warning.sanitizationSummary?.severitySummaryLines ?? [])
        if warning.archivedSnapshotURL != nil {
            informativeLines.append("The original saved workspace file was copied for recovery.")
        }
        if let archiveError = warning.archiveError {
            informativeLines.append("awesoMux could not copy the original saved workspace file: \(archiveError)")
        }
        alert.informativeText = informativeLines.joined(separator: "\n\n")

        if warning.archivedSnapshotURL != nil {
            alert.accessoryView = recoveryPathAccessoryField(for: warning)
        }

        alert.addButton(withTitle: "OK")
        if warning.archivedSnapshotURL != nil {
            alert.addButton(withTitle: "Show in Finder")
            alert.addButton(withTitle: "Copy Path")
        }
        alert.buttons[0].keyEquivalent = "\r"

        switch alert.runModal() {
        case .alertSecondButtonReturn:
            if let url = warning.archivedSnapshotURL,
                isSafeRecoveryArchiveURL(url)
            {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .alertThirdButtonReturn:
            if let path = warning.archivedSnapshotURL?.path {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        default:
            break
        }
    }

    private func recoveryPathAccessoryField(
        for warning: SessionPersistence.SessionRecoveryWarning
    ) -> NSTextField {
        let pathField = NSTextField(labelWithString: recoveryPathText(for: warning))
        pathField.isSelectable = true
        pathField.lineBreakMode = .byTruncatingMiddle
        // Size the height to the (possibly larger, at increased system text
        // sizes) font rather than pinning 22pt, which would shear descenders
        // for the low-vision user who most needs to read this recovery path.
        pathField.frame = NSRect(
            x: 0,
            y: 0,
            width: 420,
            height: ceil(pathField.fittingSize.height)
        )
        // `.byTruncatingMiddle` is visual only — VoiceOver reads the field's
        // accessibility value — but a bare path is a context-free string of
        // slashes without a label naming what it is.
        pathField.setAccessibilityLabel(recoveryPathAccessibilityLabel(for: warning))
        pathField.setAccessibilityValue(recoveryPathAccessibilityValue(for: warning))
        return pathField
    }

    private func recoveryPathText(for warning: SessionPersistence.SessionRecoveryWarning) -> String {
        if let url = warning.archivedSnapshotURL {
            return displayPath(for: url)
        }

        if let archiveError = warning.archiveError {
            return "Archive failed: \(archiveError)"
        }

        return "Archive failed."
    }

    private func recoveryPathAccessibilityLabel(
        for warning: SessionPersistence.SessionRecoveryWarning
    ) -> String {
        warning.archivedSnapshotURL == nil
            ? "Snapshot archive status"
            : "Saved snapshot location"
    }

    private func recoveryPathAccessibilityValue(
        for warning: SessionPersistence.SessionRecoveryWarning
    ) -> String {
        if let url = warning.archivedSnapshotURL {
            return url.path
        }

        return recoveryPathText(for: warning)
    }

    private func displayPath(for url: URL) -> String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        guard url.path == homePath || url.path.hasPrefix(homePath + "/") else {
            return url.path
        }

        let suffix = String(url.path.dropFirst(homePath.count))
        return suffix.isEmpty ? "~" : "~" + suffix
    }

    private func isSafeRecoveryArchiveURL(_ url: URL) -> Bool {
        guard ((try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile) == true else {
            return false
        }

        let archivePath = url.resolvingSymlinksInPath().standardized.path
        let supportPath = SessionPersistence.supportDirectoryURL
            .resolvingSymlinksInPath()
            .standardized
            .path
        return archivePath.hasPrefix(supportPath + "/")
    }
}

enum WorkspaceCommandShortcutPolicy {
    static func canRun(
        isAnySheetPresented: Bool,
        isCommandPaletteVisible: Bool,
        hasTarget: Bool
    ) -> Bool {
        !isAnySheetPresented && !isCommandPaletteVisible && hasTarget
    }
}
