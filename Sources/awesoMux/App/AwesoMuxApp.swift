import AppKit
import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers
import os
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

enum RecoveryWarningDecision: Equatable {
    case keepSavedFile
    case replaceSavedFile
    case dismissed
}

enum RecoveryReplacementFailurePresentation: Equatable {
    case reviewAfterStateChange
    case retryOrKeep
}

enum RecoveryReplacementIndicatorState: Equatable {
    case hidden
    case review
    case replacing
    case replaced

    static func resolve(
        hasWarning: Bool,
        isReplacing: Bool,
        didSucceed: Bool
    ) -> Self {
        if isReplacing { return .replacing }
        if hasWarning { return .review }
        return didSucceed ? .replaced : .hidden
    }
}

func recoveryReplacementFailurePresentation(
    for error: SessionPersistence.RecoverySnapshotReplacementError
) -> RecoveryReplacementFailurePresentation {
    error == .snapshotTooLarge ? .reviewAfterStateChange : .retryOrKeep
}

enum RecoveryWarningPresentationPolicy {
    static func didPresentAfterReviewRequest(
        hasWarning: Bool
    ) -> Bool? {
        guard hasWarning else { return nil }
        return false
    }
}

func resolveBlockedRecoveryWarningDecision(
    runModal: () -> NSApplication.ModalResponse,
    showArchive: () -> Void,
    copyPath: () -> Void
) -> RecoveryWarningDecision {
    // NSAlert exposes constants for only its first three buttons; additional
    // buttons continue the same sequential response-value convention.
    let fourthButtonResponse = NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1
    while true {
        switch runModal() {
        case .alertFirstButtonReturn:
            return .keepSavedFile
        case .alertSecondButtonReturn:
            return .replaceSavedFile
        case .alertThirdButtonReturn:
            showArchive()
        case let response where response.rawValue == fourthButtonResponse:
            copyPath()
        default:
            return .keepSavedFile
        }
    }
}

func shouldAcknowledgeRecoveryWarning(
    decision: RecoveryWarningDecision,
    allowsAutomaticWritesAfterAcknowledgement: Bool
) -> Bool {
    decision == .keepSavedFile && allowsAutomaticWritesAfterAcknowledgement
}

@main
struct AwesoMuxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sessionStore: SessionStore
    @State private var ghosttyRuntime: GhosttyRuntime
    @State private var updateController: UpdateController
    @State private var workspaceEditRequest: WorkspaceEditRequest?
    @State private var paneEditRequest: PaneEditRequest?
    @State private var workspaceGroupCreateRequest: WorkspaceGroupCreateRequest?
    @State private var remoteWorkspaceGroupCreateRequest: RemoteWorkspaceGroupCreateRequest?
    @State private var sshWorkspaceConnectRequest: SSHWorkspaceConnectRequest?
    @State private var workspaceGroupRenameRequest: WorkspaceGroupRenameRequest?
    @State private var quickSettingsRequest: QuickSettingsRequest?
    // True only after a request sheet's content actually appeared. Guards the
    // shared onDismiss replay: onDismiss semantics for an item that never
    // mounted are unverified, and a wedge-heal that nils a request must never
    // count as a dismissal (issue #202).
    @State private var activeSheetDidPresent = false
    @State private var sheetWedgeReconciliationWorkItem: DispatchWorkItem?
    @State private var recoveryWarning: SessionPersistence.SessionRecoveryWarning?
    @State private var didPresentRecoveryWarning = false
    /// The alerts are worded for launch, which is where the gate used to be
    /// only reachable from. Turning "Restore workspaces" on now validates the
    /// snapshot mid-session, with the user's workspaces sitting right there —
    /// so the launch wording ("opened with fresh workspaces") would read as
    /// though awesoMux had just wiped them.
    ///
    /// One-way for the rest of the process, not per-warning: the launch
    /// warning is assigned at `init` before any of this can run, and every
    /// warning raised after the first toggle is itself mid-session, so there is
    /// nothing to reset it for. A future site that assigns `recoveryWarning`
    /// directly would inherit the last value — set it explicitly there.
    @State private var recoveryWarningAppearedMidSession = false
    @State private var isRecoveryReplacementInProgress = false
    @State private var recoveryReplacementSuccessID: UUID?
    @State private var sessionSaveFailure: SessionPersistence.RecoverySnapshotReplacementError?
    @State private var floatingPanelController = TerminalPanelController(mode: .floating)
    @State private var popUpTerminalController = TerminalPanelController(mode: .companion)
    @State private var commandPaletteController = CommandPaletteController()
    @State private var keyboardCheatsheetController = KeyboardCheatsheetController()
    @State private var aboutPanelController = AboutPanelController()
    @State private var firstRunTourController = FirstRunTourController()
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
    @State private var settingsSectionRequest = SettingsSectionRequest()
    @State private var isCloseConfirmAlertPresented = false
    @State private var sidebarPresentationCommandMailbox = SidebarPresentationCommandMailbox()
    @State private var sidebarWidthToggleRequestID: UUID?
    @State private var isSidebarPersistentlyHidden = SidebarPresentationPreferenceStore().isHidden()
    @State private var sidebarCommandTargetAvailability = SidebarCommandTargetAvailability()
    @State private var quickRunToast: QuickRunToast?
    /// Carries the workspace order across a run of consecutive Previous/Next
    /// presses so a sticky release mid-walk can't reorder the list underfoot
    /// (INT-819). Any selection change from another path invalidates it.
    @State private var workspaceTraversalRun: WorkspaceNavigationOrder.TraversalRun?
    @State private var documentTabActions = DocumentComposeTabActionHandler()

    private static let logger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "sidebar"
    )

    private static let sheetWedgeLogger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "SheetWedgeRecovery"
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
        _ = AwesoMuxApplication.installAsSharedApplicationIfNeeded()
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
        let supportDirectoryURL = runtimeProfile.supportDirectoryURL
        // Detached so synchronous file removal does not inherit MainActor;
        // capture the actor-isolated static logger first because Logger is Sendable.
        let logger = Self.logger
        Task.detached(priority: .utility) {
            do {
                try LegacyAnalyticsCleanup.removeData(in: supportDirectoryURL)
            } catch {
                logger.error("failed to remove legacy analytics data: \(error)")
            }
        }
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
        // Seeded here for two reasons, both of which are the same bug class.
        // `loadSource` is only this launch's answer in the window between
        // `bootstrap()`, which sets it, and `startWatching()`, which turns any
        // vnode event in the config directory into a reload that rewrites it to
        // `.existingFile`. And a launch that creates the config but dies before
        // the scene mounts must still have classified itself, or launch two
        // reads `.existingFile` and permanently suppresses onboarding for a
        // genuinely new user. The write is idempotent (see the policy), so
        // running it on every launch costs nothing.
        FirstRunTourPolicy.seedSeenFlagIfNeeded(loadSource: appSettingsStore.loadSource)
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
            SessionPersistence.scheduleGeneratedDocumentPrune(keeping: store)
            loadResult = SessionPersistence.LoadResult(store: store, recoveryWarning: nil)
        }
        _appSettingsStore = State(initialValue: appSettingsStore)
        _sessionStore = State(initialValue: loadResult.store)
        if let warning = loadResult.recoveryWarning {
            switch warning.kind {
            case .archivedSnapshot, .snapshotConflict:
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
        _updateController = State(initialValue: UpdateController())
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
            // Split into chained `let` sub-expressions: this modifier chain
            // was already at the type-checker's budget, and the extra
            // `.onChange` this task adds tips it over ("unable to type-check
            // this expression in reasonable time").
            //
            // Any future animation in this root view should check
            // `@Environment(\.accessibilityReduceMotion)` before animating.
            let rootContent = ContentView(
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
                recoveryReplacementIndicatorState: RecoveryReplacementIndicatorState.resolve(
                    hasWarning: recoveryWarning != nil,
                    isReplacing: isRecoveryReplacementInProgress,
                    didSucceed: recoveryReplacementSuccessID != nil
                ),
                onReviewRecoveryWarning: reviewRecoveryWarning,
                hasSessionSaveFailure: sessionSaveFailure != nil,
                onRetrySessionSave: saveSessionIfRestoreEnabled,
                onOpenQuickSettings: requestQuickSettings,
                onShowWelcomeTour: { firstRunTourController.show() },
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
                    // Arriving at the pane is not answering its turn, though: the
                    // roster's whole workflow is cycling through waiting panes.
                    sessionStore.acknowledgeSession(id: sessionID, answersUnansweredTurn: false)
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
            .sheet(item: $workspaceEditRequest, onDismiss: handleRequestSheetDismiss) { request in
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
                .onAppear { activeSheetDidPresent = true }
            }
            .sheet(item: $paneEditRequest, onDismiss: handleRequestSheetDismiss) { request in
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
                .onAppear { activeSheetDidPresent = true }
            }
            .sheet(item: $workspaceGroupCreateRequest, onDismiss: handleRequestSheetDismiss) { _ in
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
                .onAppear { activeSheetDidPresent = true }
            }
            .sheet(item: $remoteWorkspaceGroupCreateRequest, onDismiss: handleRequestSheetDismiss) { _ in
                RemoteWorkspaceGroupCreateSheet(
                    existingGroupNames: sessionStore.groups.map(\.name),
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
                .onAppear { activeSheetDidPresent = true }
            }
            .sheet(item: $sshWorkspaceConnectRequest, onDismiss: handleRequestSheetDismiss) { request in
                SSHWorkspaceConnectSheet(
                    groupName: request.action.groupName,
                    initialDestination: request.initialDestination,
                    origin: request.origin,
                    onCancel: { sshWorkspaceConnectRequest = nil },
                    onConnect: { execution in
                        switch request.action {
                        case .convertPane(let sessionID, let paneID):
                            guard
                                reconnectPaneAsManagedSSH(
                                    sessionID: sessionID,
                                    paneID: paneID,
                                    target: execution.target,
                                    sessionName: execution.sessionName
                                )
                            else { return false }
                        case .addToGroup(let groupID, _):
                            guard
                                sessionStore.addSSHSession(
                                    target: execution.target,
                                    toGroupID: groupID,
                                    sessionName: execution.sessionName
                                ) != nil
                            else { return false }
                        }
                        appDelegate.surfacePrimaryWindow()
                        sshWorkspaceConnectRequest = nil
                        return true
                    }
                )
                .onAppear { activeSheetDidPresent = true }
            }
            .sheet(item: $workspaceGroupRenameRequest, onDismiss: handleRequestSheetDismiss) { request in
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
                .onAppear { activeSheetDidPresent = true }
            }
            .sheet(item: $quickSettingsRequest, onDismiss: handleRequestSheetDismiss) { _ in
                QuickSettingsSheet()
                    .environment(appSettingsStore)
                    .appearanceBridge(appSettingsStore)
                    .onAppear { activeSheetDidPresent = true }
            }

            let rootContentAfterAppear =
                rootContent
            .onAppear {
                // Give the floating-panel controllers the settings store so
                // their detached SwiftUI roots carry the appearance bridge
                // (accent, glow, UI font, text scale). See INT-237/INT-367.
                commandPaletteController.appSettingsStore = appSettingsStore
                keyboardCheatsheetController.appSettingsStore = appSettingsStore
                aboutPanelController.appSettingsStore = appSettingsStore
                    firstRunTourController.appSettingsStore = appSettingsStore
                    firstRunTourController.onOpenAgentSettings = { openSettingsWindow(section: .agents) }
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
                installDisplayOnlyTitleSaveHandler()
                appDelegate.updateDockBadge(total: sessionStore.unreadNotificationTotal)
                appDelegate.syncMenuBarMiniStatusItem()
                    // Inert by policy, and deliberately still here: every prime
                    // call routes through `NotificationPrimePolicy` so that one
                    // place decides, and `shouldPrime` refuses every launch
                    // evaluation. Deleting the call would leave that rule with no
                    // caller to apply it to.
                    appDelegate.requestNotificationAuthorizationIfNeeded(
                        notificationPrimeInputs(isLaunchEvaluation: true))
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

                    // Evaluated once, from this launch's snapshot. Closing the last
                    // group later returns the tree to `.firstLaunch`; that must not
                    // resurrect the tour.
                    if FirstRunTourPolicy.shouldAutoPresent(
                        seenFlag: FirstRunTourPolicy.seenFlag(),
                        mode: EmptyWorkspaceMode.resolve(
                            hasRecoveryWarning: recoveryWarning != nil,
                            hasAnyGroup: !sessionStore.groups.isEmpty))
                    {
                        firstRunTourController.show()
                    }
            }

            let rootContentAfterGroupsWatch =
                rootContentAfterAppear
            .onChange(of: sessionStore.groups) { _, _ in
                saveSessionIfRestoreEnabled()
                floatingPanelController.evictFloatingSlotsForClosedWorkspaces(in: sessionStore)
                dismissWorkspaceEditorIfTargetClosed()
                dismissWorkspaceGroupEditorIfTargetClosed()
                dismissPaneEditorIfTargetClosed()
                appDelegate.evaluateAndPostNotifications()
                    appDelegate.requestNotificationAuthorizationIfNeeded(
                        notificationPrimeInputs(isLaunchEvaluation: false))
                appDelegate.syncMenuBarMiniStatusItem()
            }
                .onChange(of: appSettingsStore.notifications.value) { (_: NotificationConfig, _: NotificationConfig) in
                    appDelegate.requestNotificationAuthorizationIfNeeded(
                        notificationPrimeInputs(isLaunchEvaluation: false))
                }
                // The prime policy *defers* while the tour is up below beat
                // three, and nothing else brings the evaluation back: menu
                // chords stay live over the tour, so a user who follows beat
                // one's "press ⌘N" mutates `groups` during the deferral, and
                // paging on to Done mutates nothing at all. Without this the
                // explanation is never shown and the first real agent event
                // fires the bare system dialog — exactly what the pre-prompt
                // exists to prevent.
                .onChange(of: firstRunTourController.isDeferringNotificationPrime) { _, isDeferring in
                    guard !isDeferring else { return }
                    appDelegate.requestNotificationAuthorizationIfNeeded(
                        notificationPrimeInputs(isLaunchEvaluation: false))
                }
                // The empty state's one-shot VoiceOver focus request is
                // suppressed while the tour is up, and its own retry observers
                // watch the MAIN window — which fires nothing when the tour is
                // closed from behind Settings. Restore explicitly instead.
                .onChange(of: firstRunTourController.isVisible) { _, isVisible in
                    guard !isVisible else { return }
                    NotificationCenter.default.post(
                        name: .awEmptyWorkspaceInitialFocusShouldRestore, object: NSApp)
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
            // Both general-config reactions share one modifier: this chain is
            // already at the type-checker's limit and one more tips it over.
            .onChange(of: appSettingsStore.general.value) { previous, current in
                if previous.showMenuBarMiniStatus != current.showMenuBarMiniStatus {
                    appDelegate.syncMenuBarMiniStatusItem()
                }
                if previous.restoreWorkspaces != current.restoreWorkspaces {
                    restoreWorkspacesSettingDidChange(isEnabled: current.restoreWorkspaces)
                }
            }
            .onChange(of: appSettingsStore.workspaces.value.outputMarksNeedsAttention) { _, _ in
                appDelegate.evaluateAndPostNotifications()
            }

            rootContentAfterGroupsWatch
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
            // Sheet-wedge recovery triggers (issue #202): scenePhase is too
            // coarse on macOS and sleep/wake can fire neither activation
            // notification (see SidebarSplitController's trigger set), so key
            // on all three. Cheap no-ops when nothing is pending.
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )
            ) { _ in
                scheduleSheetWedgeReconciliation()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            ) { _ in
                scheduleSheetWedgeReconciliation()
            }
            .onReceive(
                NSWorkspace.shared.notificationCenter.publisher(
                    for: NSWorkspace.didWakeNotification
                )
                // Workspace notifications deliver on the posting thread;
                // the reconciler reads AppKit and SwiftUI state.
                .receive(on: DispatchQueue.main)
            ) { _ in
                scheduleSheetWedgeReconciliation()
            }
            // Arm on intent transitions too: a wedge that forms with no
            // later activation signal (e.g. a view-state task setting a
            // request) would otherwise wait for a keypress on a gated
            // command. A legitimate mount attaches its sheet well inside
            // the beat and vetoes itself at recheck.
            .onChange(of: isAnySheetPresented) { wasPresented, isPresented in
                if !wasPresented, isPresented {
                    scheduleSheetWedgeReconciliation(trigger: "intentTransition")
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .awesoMuxManagedSSHOfferReplayRequested
                )
            ) { _ in
                replayQueuedManagedSSHOffer()
            }
            .onReceive(NotificationCenter.default.publisher(for: .awesoMuxFocusSidebarRequested)) { _ in
                requestSidebarFocus()
            }
            .onReceive(NotificationCenter.default.publisher(for: .awesoMuxToggleSidebarWidthRequested)) { _ in
                requestSidebarWidthToggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .awesoMuxToggleSidebarVisibilityRequested)) { _ in
                requestSidebarVisibilityToggle()
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
            .environment(updateController)
            .environment(documentTabActions)
                .environment(firstRunTourController)
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
            AboutCommands(aboutPanelController: aboutPanelController)
            SettingsCommands()
            NewWorkspaceCommands(
                sessionStore: sessionStore,
                appSettingsStore: appSettingsStore,
                shortcut: shortcut(KeyboardShortcutCatalog.newWorkspace)
            )

            CommandGroup(after: .appInfo) {
                Button(
                    String(
                        localized: "Check for Updates…",
                        comment: "App menu command that explicitly checks for awesoMux updates"
                    )
                ) {
                    updateController.checkForUpdates()
                }
                .disabled(!updateController.canCheckForUpdates)
            }

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

            // MARK: - View menu

            CommandGroup(after: .sidebar) {
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
                    // A real `.keyboardShortcut` auto-repeats its action while
                    // held, unlike the deleted NSEvent interceptor which
                    // explicitly swallowed repeats. Scoped to THIS closure
                    // (not `toggleCommandPalette()` itself) so the sidebar's
                    // magnifying-glass button and the palette's own
                    // "Command Palette" list entry — both call
                    // `toggleCommandPalette()` too — are never gated on
                    // ambient `NSApp.currentEvent`, which reflects whatever
                    // the app last dispatched, not what triggered THEIR call.
                    guard !(NSApp.currentEvent?.type == .keyDown && NSApp.currentEvent?.isARepeat == true) else {
                        ShortcutDiagnostics.log("stage=commandPaletteMenuAction repeat=true action=ignore")
                        return
                    }
                    toggleCommandPalette()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.toggleCommandPalette))
                .disabled(isAnySheetPresented)

                Button("Session Manager") {
                    toggleSessionManager()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.sessionManager))
                .disabled(isAnySheetPresented)

                // AppKit appends its own "Enter Full Screen" below this group.
                // Without a trailing separator our items run straight into it.
                Divider()
            }

            // MARK: - Workspace menu

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

                // Also disabled with no groups: `SSHWorkspaceGroupTargeting`
                // ends in `?? groups.first`, so an empty tree resolves to nil
                // and the command silently does nothing. Closing the last
                // group is now a deliberate destination rather than a
                // transient launch state, so that no-op is reachable and
                // sitting in.
                Button("Connect via SSH…") { requestConnectViaSSH() }
                    .disabled(isAnySheetPresented || sessionStore.groups.isEmpty)

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
                    showWorktreeManager()
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

                // Presets capture the whole workspace's split arrangement, not a
                // single pane — `saveLayoutPresetForSelectedWorkspace()` is scoped
                // to the workspace, and ADR-0027 documents them living here.
                Button("Save Layout as Preset…") {
                    saveLayoutPresetForSelectedWorkspace()
                }
                .disabled(sessionStore.selectedSession == nil || isAnySheetPresented)

                Button("Apply Layout Preset…") {
                    applyLayoutPresetViaPicker()
                }
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

                let jumpRows = DockRecentWorkspaceMenu.openWorkspaceRows(
                    groups: sessionStore.groups,
                    liftedSessionIDs: sessionStore.liftedSessionIDs,
                    pinnedSessionIDs: sessionStore.pinnedSessionIDs,
                    activeID: sessionStore.selectedSessionID
                )
                ForEach(
                    Array(shortcuts(KeyboardShortcutCatalog.jumpWorkspaces).enumerated()),
                    id: \.element.id
                ) { offset, binding in
                    // Label with the real workspace title ⌘N lands on; both this
                    // list and the jump action resolve through the same lifted-first
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

                if let shortcutDiagnosticsURL = ShortcutDiagnostics.fileURL {
                    Divider()

                    Button("Copy Shortcut Diagnostics Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(shortcutDiagnosticsURL.path, forType: .string)
                    }
                }

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

            // MARK: - Pane menu

            CommandMenu("Pane") {
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

                Divider()

                // Same conditional as the File-menu binding: closeActivePane()
                // routes single-pane sessions through closeWorkspace(_:), so
                // the title has to match what actually happens.
                Button(closePaneMenuTitle) {
                    closeActivePane()
                }
                .disabled(sessionStore.selectedSessionID == nil || isAnySheetPresented)

                // Binds ⌘⌥R, which the palette already advertises — without this
                // menu item the shortcut was shown but not wired (Codex).
                Button("Rename Pane…") {
                    requestRenameActivePane()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.renamePane))
                .disabled(!selectedSessionHasMultiplePanes || isAnySheetPresented)

                Divider()

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

                // Gated exactly like its neighbours and no further. Whether the
                // pane's agent HAS a readable transcript is a question with six
                // different answers, each of which the user can act on — so the
                // command stays live and explains, rather than greying out and
                // leaving them to guess which of the six applies.
                Button(
                    String(
                        localized: "Open Agent Transcript",
                        comment: "Workspace menu item that opens the active pane's agent session as a document"
                    )
                ) {
                    openAgentTranscriptForActivePane()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.openAgentTranscript))
                .disabled(sessionStore.selectedSessionID == nil || isAnySheetPresented)
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

                // Always render every slot. Per ADR-0002 SwiftUI claims a chord
                // even when the command is disabled, so a rendered row is how
                // awesoMux holds ⌥⌘N; dropping the row hands the chord to
                // libghostty. Matches the ⌘1–9 workspace jump rows above.
                ForEach(
                    Array(shortcuts(KeyboardShortcutCatalog.focusPaneBindings).enumerated()),
                    id: \.element.id
                ) { offset, binding in
                    // The bindings are built from a `1...n` range in order, so the
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

                // The keyboard counterpart of the transcript tab's Resume
                // button, which refuses first responder (INT-562) and is
                // therefore unreachable with Full Keyboard Access — same class
                // of fix as Close Document Tab above (review finding).
                Button(
                    String(
                        localized: "Resume Agent Session",
                        comment: "Workspace menu item that stages the selected transcript's resume command in its terminal"
                    )
                ) {
                    resumeSelectedTranscriptSession()
                }
                .keyboardShortcut(shortcut(KeyboardShortcutCatalog.resumeAgentSession))
                // Gated like its neighbours, NOT on whether a transcript tab is
                // selected. A disabled command does not consume its key
                // equivalent, so gating on the tab let ⌃⌘R fall through to
                // libghostty, which echoed a CSI-u sequence into the shell.
                // With no transcript selected the command now runs and says so.
                .disabled(sessionStore.selectedSessionID == nil || isAnySheetPresented)

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

                // Cross-workspace moves, grouped apart from the
                // in-workspace rearrange rows above. Deliberately chordless —
                // no `KeyboardShortcutCatalog` entry, so ADR-0002's
                // render-the-row-to-hold-the-chord rule has nothing to hold.
                Button("Move Pane to New Workspace") {
                    moveActivePaneToNewWorkspace()
                }
                .disabled(!canMoveActivePaneToNewWorkspace)

                Button("Return Pane to Source Workspace") {
                    returnActivePaneToSourceWorkspace()
                }
                .disabled(!canReturnActivePaneToSourceWorkspace)

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
            }

            CommandGroup(replacing: .help) {
                Button(keyboardCheatsheetMenuTitle) {
                    toggleKeyboardCheatsheet()
                }
                // Interceptor-only by design: Cmd-/ still routes through
                // `AwesoMuxApplication.sendEvent`'s `KeyboardCheatsheetShortcut`
                // branch. Migrating it to a real `.keyboardShortcut` (the fix
                // Command Palette got in INT-643) is a separate follow-up.
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
                .environment(settingsSectionRequest)
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
        guard let session = selectedWorkspaceActionSession() else {
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
        // `session.title` is the title visible when the action was invoked.
        // Mutable state and destructive ownership still come from `live` and
        // the post-alert refetches below.
        let voTitle = Self.compactTitle(session.title)

        // Mirror the ⌘Q path: refresh per-pane prompt-marker quit state so
        // the close gate sees the same truth as `applicationShouldTerminate`.
        // Otherwise a busy `vim` pane in the same session is invisible to
        // the prompt — ⌘Q would prompt, ⌘W would not.
        ghosttyRuntime.refreshTerminalQuitConfirmationRisks(in: sessionStore)
        floatingPanelController.refreshTerminalQuitConfirmationRisks(using: ghosttyRuntime)

        guard let refreshed = sessionStore.session(id: live.id) else { return }

        let decision = confirmCloseIfNeeded(
            refreshed,
            displayedTitle: session.title,
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
        guard let session = selectedWorkspaceActionSession() else {
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
        let voTitle = Self.compactTitle(session.title)

        ghosttyRuntime.refreshTerminalQuitConfirmationRisks(in: sessionStore)
        floatingPanelController.refreshTerminalQuitConfirmationRisks(using: ghosttyRuntime)

        guard let refreshed = sessionStore.session(id: live.id) else { return }

        switch confirmClearWorkspace(refreshed, displayedTitle: session.title) {
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
    private func confirmClearWorkspace(
        _ session: TerminalSession,
        displayedTitle: String
    ) -> CloseConfirmDecision {
        guard !isCloseConfirmAlertPresented else { return .suppressed }
        isCloseConfirmAlertPresented = true
        defer { isCloseConfirmAlertPresented = false }

        let displayTitle = Self.sanitizedAlertTitle(displayedTitle)
        let now = Date()
        let floatingAtRisk = floatingPanelController.hasRiskyFloatingSessionsOnClose(for: session.id)
        let atRisk = session.isCloseRisk(at: now) || floatingAtRisk
        if atRisk {
            logCloseRiskConfirmation(
                trigger: "clear-workspace",
                session: session,
                at: now,
                floatingPanelAtRisk: floatingAtRisk
            )
        }

        // Whole sentences, composed: the pane mix decides what the close can
        // actually end, and `killClearedDaemons` never reaches a session the
        // remote host owns.
        let body = DestructiveCloseCopy.clearWorkspaceBody(
            title: displayTitle,
            hasInterruptedActivity: atRisk,
            summary: SessionGroupExecutionSummary(sessions: [session])
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
            // `removeGroup` refuses a group that gained a workspace between
            // the context menu rendering and this invoke (the re-fetch above
            // is what makes that reachable) — only announce a removal that
            // actually happened.
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
        let riskySessions =
            workspaces.confirmCloseWithRunningAgent
            ? group.sessions.filter {
                $0.isCloseRisk(at: now) || floatingPanelController.hasRiskyFloatingSessionsOnClose(for: $0.id)
            }
            : []
        let riskyCount = riskySessions.count
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

        for session in riskySessions {
            logCloseRiskConfirmation(
                trigger: "close-group",
                session: session,
                at: now,
                floatingPanelAtRisk: floatingPanelController.hasRiskyFloatingSessionsOnClose(
                    for: session.id
                )
            )
        }

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
        displayedTitle: String,
        alsoGateOnPaneActionConfirm: Bool = false
    ) -> CloseConfirmDecision {
        let workspaces = appSettingsStore.workspaces.value
        // Check both the main session AND any backgrounded floating-panel
        // session bound to this workspace. `evictFloatingSlot` tears down
        // floating sessions unconditionally as part of close, so a workspace
        // with an idle sidebar pane but a running agent in its floating slot
        // would otherwise be killed silently. Close-scoped (see doc above),
        // unlike the ⌘Q path's `floatingPanelController.sessionsAtRiskOnQuit`.
        let now = Date()
        let mainAtRisk = session.isCloseRisk(at: now)
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

        logCloseRiskConfirmation(
            trigger: "close-workspace",
            session: session,
            at: now,
            floatingPanelAtRisk: floatingAtRisk
        )

        let displayTitle = Self.sanitizedAlertTitle(displayedTitle)

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
        displayedTitle: String,
        riskReason: QuitRiskReason?,
        at now: Date
    ) -> CloseConfirmDecision {
        guard !isCloseConfirmAlertPresented else { return .suppressed }
        isCloseConfirmAlertPresented = true
        defer { isCloseConfirmAlertPresented = false }

        if riskReason != nil {
            logCloseRiskConfirmation(
                trigger: action == .closePane ? "close-pane" : "restart-shell",
                session: session,
                at: now
            )
        }

        let displayTitle = Self.sanitizedAlertTitle(displayedTitle)

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
                riskReason != nil
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
            body = DestructivePaneActionConfirmationPolicy.closePaneConfirmationBody(
                displayTitle: displayTitle,
                agentKind: session.activePane?.agentKind,
                riskReason: riskReason
            )
        }

        return NSAlert.confirmDestructive(
            title: title,
            body: body,
            keyboardHint: action.keyboardHint,
            destructiveTitle: action.destructiveButtonTitle
        ) ? .proceed : .userCancelled
    }

    /// Issue #190 mechanism 3: the confirmation chain used to discard WHY a
    /// pane is close-risky, so a false "activity" warning was unattributable
    /// in the field. Logs every risky pane's reason plus the raw quit-risk
    /// inputs at the moment a close-risk dialog fires.
    private static let closeRiskLogger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "CloseRiskConfirm"
    )

    /// `now` must be the SAME timestamp the caller's risk gate used — a fresh
    /// clock read here can disagree with the gate at the 60s agent-staleness
    /// seam and record "no risky pane" for a dialog that just fired.
    private func logCloseRiskConfirmation(
        trigger: String,
        session: TerminalSession,
        at now: Date,
        floatingPanelAtRisk: Bool = false
    ) {
        for pane in session.panes {
            guard let reason = pane.closeRiskReason(at: now) else { continue }
            Self.closeRiskLogger.info(
                "close-risk confirm (\(trigger, privacy: .public)): pane \(pane.id.uuidString, privacy: .public) agent=\(pane.agentKind.rawValue, privacy: .public) reason=\(String(describing: reason), privacy: .public) liveness=\(String(describing: pane.foregroundProcessLiveness), privacy: .public) promptObserved=\(pane.terminalPromptObserved, privacy: .public) awayFromPrompt=\(pane.needsTerminalQuitConfirmation, privacy: .public) exec=\(String(describing: pane.agentExecutionState), privacy: .public)"
            )
        }
        if floatingPanelAtRisk {
            // The floating-slot store isn't enumerable from here; without this
            // line a floating-panel-only risk would fire the dialog and log
            // nothing — the exact unattributability #190 mechanism 3 fixes.
            Self.closeRiskLogger.info(
                "close-risk confirm (\(trigger, privacy: .public)): session \(session.id.uuidString, privacy: .public) risky floating-panel session (panes not enumerated)"
            )
        }
    }

    /// The flip side of `logCloseRiskConfirmation`: a bridged pane that closes
    /// WITHOUT a dialog destroys its daemon session on a single probe sample,
    /// so a misclassification would otherwise leave no forensic trail at all
    /// (issue #190 security-review follow-through). Non-bridged panes stay
    /// unlogged — their silent close was always the norm.
    private func logSilentBridgedCloseIfNeeded(in session: TerminalSession, at now: Date) {
        guard let pane = session.activePane else { return }
        switch pane.foregroundProcessLiveness {
        case .bridged, .bridgedBusy, .bridgedIndeterminate: break
        default: return
        }
        let decision = pane.closeRiskDecision(at: now)
        Self.closeRiskLogger.debug(
            "close-pane without confirm: pane \(pane.id.uuidString, privacy: .public) agent=\(pane.agentKind.rawValue, privacy: .public) risk=\(decision.isRisk, privacy: .public) reason=\(String(describing: decision.reason), privacy: .public) liveness=\(String(describing: pane.foregroundProcessLiveness), privacy: .public) promptObserved=\(pane.terminalPromptObserved, privacy: .public) awayFromPrompt=\(pane.needsTerminalQuitConfirmation, privacy: .public)"
        )
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

    private func signalPaletteTargetUnavailable() {
        NSSound.beep()
        DispatchQueue.main.async {
            let announcement = String(
                localized: "The command palette changed. Open it and choose again.",
                comment:
                    "VoiceOver announcement when a command palette action is rejected because its captured target or availability changed."
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

    /// The selected document tab, when it is an app-rendered agent transcript.
    /// Scoped to the selection rather than the whole group: Resume stages the
    /// selected document's own session.
    private var selectedSessionTranscriptTab: DocumentPane? {
        sessionStore.selectedSession?.layout.firstDocumentGroup?.selectedTab
            .flatMap { $0.agentTranscriptIdentity == nil ? nil : $0 }
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

    private var canMoveActivePaneToNewWorkspace: Bool {
        guard let session = sessionStore.selectedSession else {
            return false
        }
        return sessionStore.canMovePaneToNewWorkspace(
            id: session.activePaneID,
            in: session.id
        )
    }

    /// Moves the active pane out into a workspace row of its own. The store
    /// selects the new row, so the announcement reports the destination rather
    /// than a pane index.
    private func moveActivePaneToNewWorkspace() {
        guard let session = sessionStore.selectedSession,
            sessionStore.movePaneToNewWorkspace(
                id: session.activePaneID,
                in: session.id
            ) != nil
        else {
            return
        }
        postAccessibilityAnnouncement(
            String(
                localized: "Moved pane to a new workspace",
                comment:
                    "VoiceOver announcement after moving the active pane out into a workspace of its own."
            ))
    }

    private var canReturnActivePaneToSourceWorkspace: Bool {
        guard let sessionID = sessionStore.selectedSessionID else {
            return false
        }
        return sessionStore.canReturnPaneToSourceWorkspace(sessionID: sessionID)
    }

    /// The one-shot inverse of the move. Workspace-scoped, not pane-scoped: the
    /// whole row goes back, and the store re-validates the recorded origin.
    private func returnActivePaneToSourceWorkspace() {
        guard let sessionID = sessionStore.selectedSessionID,
            sessionStore.returnPaneToSourceWorkspace(sessionID: sessionID)
        else {
            return
        }
        postAccessibilityAnnouncement(
            String(
                localized: "Returned pane to its source workspace",
                comment:
                    "VoiceOver announcement after returning a moved pane to the workspace it came from."
            ))
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

    // ⌘1-9 jump and Previous/Next resolve from the sidebar's lifted-first visual
    // order (INT-737) so a ⌘-digit lands on the tile showing that badge. Stays
    // filter-blind — as this action side always was — since the sidebar's
    // filtered badge snapshot is view-local and out of scope to thread here.
    private func workspaceNavigationOrder() -> [TerminalSession.ID] {
        WorkspaceNavigationOrder.liftedFirstSessionIDs(
            in: sessionStore.groups,
            liftedSessionIDs: sessionStore.liftedSessionIDs,
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
        guard
            let step = WorkspaceNavigationOrder.step(
                offset: offset,
                currentSelection: sessionStore.selectedSessionID,
                run: workspaceTraversalRun,
                freshOrder: workspaceNavigationOrder()
            )
        else {
            workspaceTraversalRun = nil
            return
        }
        sessionStore.selectedSessionID = step.selection
        workspaceTraversalRun = step.run
    }

    /// Pane-scoped title only — no window fallback. The Pane menu's
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
        return "\(action) Command Palette"
    }

    private var sidebarVisibilityMenuTitle: String {
        SidebarVisibilityActionTitle.resolve(isHidden: isSidebarPersistentlyHidden)
    }

    private var keyboardCheatsheetMenuTitle: String {
        "Keyboard Shortcuts    \(shortcut(KeyboardShortcutCatalog.showKeyboardCheatsheet).displaySymbol)"
    }

    private func closeActivePaneOrWindow() {
        healSheetWedgeBeforeGatedCommand()
        if sessionManagerController.hideIfKeyWindow() {
            return
        }

        if keyboardCheatsheetController.hideIfKeyWindow() {
            return
        }

        if commandPaletteController.hideIfKeyWindow() {
            return
        }

        if aboutPanelController.hideIfKeyWindow() {
            return
        }

        if firstRunTourController.hideIfKeyWindow() {
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
        // of a menu item, so it needs the guard explicitly. This runs BEFORE
        // the auxiliary-window routing below: a presented sheet is its own key
        // NSWindow, and swallowing here keeps Cmd-W from force-closing it.
        guard !isAnySheetPresented else { return }

        // Cmd-W is a global menu command — it fires regardless of which window
        // holds key. When an auxiliary scene window (Settings, About) is key,
        // close THAT window instead of destroying a pane in the primary window
        // behind it. Fail-closed on role: an unclassified/primary key window
        // (including the primary before its role is assigned) falls through to
        // normal pane routing rather than being force-closed.
        if let keyWindow = NSApp.keyWindow,
            AwesoMuxWindowRole.isAuxiliaryCloseTarget(keyWindow.awesoMuxWindowRole)
        {
            keyWindow.performClose(nil)
            return
        }

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

        guard let source = sessionStore.session(id: sessionID) else { return }
        let actionSession = workspaceActionSession(source)
        ghosttyRuntime.refreshTerminalQuitConfirmationRisks(in: sessionStore)
        guard let session = sessionStore.session(id: sessionID) else { return }

        // Last pane = the workspace: route through the same soft-close funnel as
        // the sidebar X (confirm gate, floating-slot eviction, recently-closed
        // capture) instead of recycling the shell in place. ⇧⌘T reopens.
        // `alsoGateOnPaneActionConfirm: true` — this is still logically a pane
        // action (⌘W), so a user who only enabled the pane-confirm toggle
        // (not the workspace one) keeps that protection here too.
        if session.layout.isSinglePane {
            closeWorkspace(actionSession, alsoGateOnPaneActionConfirm: true)
            return
        }

        let targetPaneID = session.activePaneID
        let action: DestructivePaneActionConfirmationPolicy.Action
        // One clock read for the gate, the risk-reason recompute, and the
        // silent-close log — see `logCloseRiskConfirmation`'s seam warning.
        let now = Date()
        switch DestructivePaneActionConfirmationPolicy.decision(
            session: session,
            workspaces: appSettingsStore.workspaces.value,
            now: now
        ) {
        case .unavailable:
            return
        case let .proceedWithoutPrompt(resolvedAction):
            logSilentBridgedCloseIfNeeded(in: session, at: now)
            action = resolvedAction
        case let .prompt(resolvedAction):
            // `.prompt` is only ever returned when the policy already found
            // the active pane at risk (see `DestructivePaneActionConfirmationPolicy.decision`),
            // but recomputing here — rather than hardcoding `true` — keeps this
            // call site honest if that gate ever changes independently.
            let riskReason = session.activePane.flatMap { $0.closeRiskReason(at: now) }
            switch confirmDestructivePaneActionIfNeeded(
                resolvedAction,
                in: session,
                displayedTitle: actionSession.title,
                riskReason: riskReason,
                at: now
            ) {
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
                var refreshedActionSession = refreshed
                refreshedActionSession.title = actionSession.title
                closeWorkspace(refreshedActionSession, alsoGateOnPaneActionConfirm: false)
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
        guard let actionSession = selectedWorkspaceActionSession() else { return }
        ghosttyRuntime.refreshTerminalQuitConfirmationRisks(in: sessionStore)
        guard let refreshed = sessionStore.session(id: actionSession.id) else { return }
        let now = Date()
        let riskReason = refreshed.activePane.flatMap { $0.closeRiskReason(at: now) }

        switch confirmDestructivePaneActionIfNeeded(
            .restartShell,
            in: refreshed,
            displayedTitle: actionSession.title,
            riskReason: riskReason,
            at: now
        ) {
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
        guard let session = selectedWorkspaceActionSession() else {
            return
        }

        requestRenameWorkspace(session)
    }

    private func selectedWorkspaceActionSession() -> TerminalSession? {
        guard let session = sessionStore.selectedSession else { return nil }
        return workspaceActionSession(session)
    }

    private func workspaceActionSession(_ source: TerminalSession) -> TerminalSession {
        var session = source
        session.title = sessionStore.sidebarResolvedTitle(for: session.id) ?? session.displayTitle()
        return session
    }

    private func requestRenameWorkspace(_ session: TerminalSession) {
        guard !isAnySheetPresented else {
            return
        }
        guard let currentSession = sessionStore.session(id: session.id) else {
            return
        }

        workspaceEditRequest = WorkspaceEditRequest(
            id: session.id,
            title: currentSession.title
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
            origin: .explicitConnection,
            action: .addToGroup(id: group.id, name: group.name)
        )
    }

    private func requestManagedSSHWorkspaceOffer(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID
    ) {
        // Resolve against a peek, so the sheet-stacking guard below can apply
        // to the arm that actually presents a sheet. Bailing before the consume
        // used to drop an ask-free conversion whenever any unrelated sheet was
        // open, permanently — the pane's `.task(id:)` does not fire again for
        // the same identity.
        let pendingEffect = ManagedSSHOfferEffect.resolve(
            target: sessionStore.pendingManagedSSHWorkspaceOffer(
                sessionID: sessionID,
                paneID: paneID
            ),
            config: appSettingsStore.workspaces.value
        )
        if pendingEffect == .doNothing || (pendingEffect == .present && isAnySheetPresented) {
            return
        }
        guard
            let target = sessionStore.consumeManagedSSHWorkspaceOffer(
                sessionID: sessionID,
                paneID: paneID
            )
        else { return }

        ManagedSSHOfferEnactor.enact(
            pendingEffect,
            convert: { sessionName in
                reconnectPaneAsManagedSSH(
                    sessionID: sessionID,
                    paneID: paneID,
                    target: target,
                    sessionName: sessionName
                )
            },
            present: {
                sshWorkspaceConnectRequest = SSHWorkspaceConnectRequest.automaticOffer(
                    sessionID: sessionID,
                    paneID: paneID,
                    target: target
                )
            },
            confirm: {
                announceManagedSSHConversion(target: target)
            }
        )
    }

    /// The conversion discards the pane's surface and its scrollback, and the
    /// Path Bar looks identical afterwards because the pane was already showing
    /// a remote host. Without this the only notification of any of that was an
    /// assistive-technology announcement — a VoiceOver user got a sentence
    /// nobody else did, and the sighted user just watched their terminal blink.
    private func announceManagedSSHConversion(target: RemoteTarget) {
        // Deliberately not "Connected": `convertPaneToManagedSSH` swaps the
        // pane's execution plan and recycles it, and the `ssh` child spawns
        // afterwards. Nothing has been dialled yet, so a failed connection
        // would have been preceded by an announcement claiming success.
        let message = String(
            localized: "Reconnecting as a managed workspace. The previous shell and its scrollback were replaced.",
            comment: "Notice shown when an SSH pane is reconnected as managed without asking"
        )
        quickRunToast = QuickRunToast(
            id: UUID(),
            command: target.sshDestination,
            output: message,
            state: .notice(
                kicker: String(
                    localized: "Managed",
                    comment: "Kicker on the notice shown when an SSH pane becomes a managed workspace"
                )
            )
        )
        scheduleQuickRunToastDismissal(id: quickRunToast?.id ?? UUID())
        TerminalAccessibilityAnnouncer.announce(
            "\(target.sshDestination). \(message)",
            priority: .high
        )
    }

    /// Converts the pane in place and discards its old surface so the managed
    /// replacement can attach. Returns false when the pane or its workspace is
    /// gone, or when local-amx persistence would need a command bridge that is
    /// switched off.
    ///
    /// No `sessionName` default: both callers pass it, and the default was what
    /// made dropping the argument compile — which is exactly the owner
    /// inversion this signature exists to prevent. Let the compiler enforce it.
    private func reconnectPaneAsManagedSSH(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        target: RemoteTarget,
        sessionName: RemoteSessionName?
    ) -> Bool {
        // Local-amx persistence needs the command bridge, and this refuses to
        // turn it on. It is a global setting governing how every pane in the
        // app is spawned and whether shells outlive their pane, so a
        // preference remembered for one destination is not consent to change
        // it — least of all silently, over a decline the user made later in
        // Settings. Refusing routes the ask-free path back to the prompt,
        // whose button says "Enable and Reconnect" and asks properly.
        // A remote-owned session runs with no local daemon and never needs it.
        if sessionName == nil, !appSettingsStore.terminal.value.commandBridgeEnabled {
            return false
        }
        guard
            let discardedPaneID = sessionStore.convertPaneToManagedSSH(
                sessionID: sessionID,
                paneID: paneID,
                target: target,
                sessionName: sessionName
            )
        else { return false }
        ghosttyRuntime.discardSurface(for: discardedPaneID)
        return true
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

    // MARK: - Sheet wedge recovery (issue #202)

    /// Replaces the old `.onChange(of: isAnySheetPresented)` offer replay.
    /// `onDismiss` fires per dismissed sheet, and the presented-mark keeps a
    /// wedge heal (or an item that never mounted) from replaying the queued
    /// managed-SSH offer during a dismissal that never visually happened.
    private func handleRequestSheetDismiss() {
        // Every genuine sheet close is also a reconciliation trigger: a wedge
        // that coexisted with a live sheet would otherwise persist until the
        // next activation signal, which a continuous foreground session may
        // never produce.
        scheduleSheetWedgeReconciliation(trigger: "sheetDismiss")
        guard activeSheetDidPresent else { return }
        activeSheetDidPresent = false
        replayQueuedManagedSSHOffer()
    }

    private func replayQueuedManagedSSHOffer() {
        guard let session = sessionStore.selectedSession,
            let paneID = session.activePane?.id
        else { return }
        requestManagedSSHWorkspaceOffer(sessionID: session.id, paneID: paneID)
    }

    private var sheetWedgeSnapshot: SheetWedgeRecoveryPolicy.Snapshot {
        let primaryWindow = AwesoMuxWindowRole.primaryContentWindow(
            mainWindow: NSApp.mainWindow,
            keyWindow: NSApp.keyWindow,
            windows: NSApp.windows
        )
        return .init(
            pendingRequestKeys: SheetWedgeRecoveryPolicy.pendingRequestKeys(
                workspaceEdit: workspaceEditRequest != nil,
                paneEdit: paneEditRequest != nil,
                workspaceGroupCreate: workspaceGroupCreateRequest != nil,
                remoteWorkspaceGroupCreate: remoteWorkspaceGroupCreateRequest != nil,
                sshWorkspaceConnect: sshWorkspaceConnectRequest != nil,
                workspaceGroupRename: workspaceGroupRenameRequest != nil,
                quickSettings: quickSettingsRequest != nil
            ),
            scrollbackDumpPaneIDs: Set(ghosttyRuntime.scrollbackDumpSheetPaneIDsSnapshot),
            hasModalWindow: NSApp.modalWindow != nil,
            primaryWindowSheetAttached: primaryWindow?.attachedSheet != nil,
            anyWindowSheetAttached: NSApp.windows.contains { $0.attachedSheet != nil }
        )
    }

    /// A sheet-request var whose sheet never mounted wedges non-nil forever —
    /// its dismiss handlers live inside content that never appeared — which
    /// invisibly disables ⌘F, ⌘W, and the workspace command surface via
    /// `isAnySheetPresented`. On every activation signal, compare request
    /// intent against AppKit presentation truth across a stabilization beat
    /// and clear what is genuinely wedged, logging the operands so the next
    /// occurrence names its trigger. The policy's recheck is the single veto
    /// point — no early modal bail, so a modal closing inside the beat does
    /// not forfeit the healing opportunity.
    private func scheduleSheetWedgeReconciliation(trigger: String = "activation") {
        let initial = sheetWedgeSnapshot
        guard !initial.pendingRequestKeys.isEmpty || !initial.scrollbackDumpPaneIDs.isEmpty
        else { return }
        sheetWedgeReconciliationWorkItem?.cancel()
        // Dispatched to the main queue, but the closure is not statically
        // MainActor-isolated — assert it so the contract survives a future
        // refactor, matching the work-item convention elsewhere in the app.
        let workItem = DispatchWorkItem {
            MainActor.assumeIsolated {
                performSheetWedgeHeal(
                    initial: initial,
                    recheck: sheetWedgeSnapshot,
                    trigger: trigger
                )
            }
        }
        sheetWedgeReconciliationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    /// A keypress on a gated command is unambiguous user intent: heal
    /// synchronously (same snapshot both sides — the stabilization grace is
    /// traded for the certainty that the user is staring at a dead command),
    /// so the very press that found the command dead un-wedges it. Activation
    /// notifications never fire for a keypress in an already-active key
    /// window, which is exactly the reported repro state.
    private func healSheetWedgeBeforeGatedCommand() {
        let snapshot = sheetWedgeSnapshot
        performSheetWedgeHeal(initial: snapshot, recheck: snapshot, trigger: "gatedCommand")
    }

    private func performSheetWedgeHeal(
        initial: SheetWedgeRecoveryPolicy.Snapshot,
        recheck: SheetWedgeRecoveryPolicy.Snapshot,
        trigger: String
    ) {
        let keys = SheetWedgeRecoveryPolicy.keysToHeal(initial: initial, recheck: recheck)
        guard !keys.isEmpty else { return }
        // Unconditional logger, not ShortcutDiagnostics: a wedge heal is rare,
        // carries only fixed keys/booleans/counts, and is most needed in
        // shipped builds where the diagnostics env var is never set.
        Self.sheetWedgeLogger.notice(
            "sheetWedgeHeal trigger=\(trigger, privacy: .public) keys=\(keys.sorted().joined(separator: ","), privacy: .public) modalWindow=\(recheck.hasModalWindow, privacy: .public) primarySheet=\(recheck.primaryWindowSheetAttached, privacy: .public) anySheet=\(recheck.anyWindowSheetAttached, privacy: .public) selectedSession=\(sessionStore.selectedSessionID != nil, privacy: .public) scrollbackPanes=\(recheck.scrollbackDumpPaneIDs.count, privacy: .public)"
        )
        healWedgedSheetRequests(
            keys,
            scrollbackPaneIDs: SheetWedgeRecoveryPolicy.scrollbackPaneIDsToHeal(
                initial: initial,
                recheck: recheck
            )
        )
        // An offer that arrived while the wedge gated its setter was never
        // consumed, and nothing else re-triggers it (the pane's task ID is
        // unchanged and the presented-mark suppresses the dismiss replay).
        // Replay on the next turn, once the cleared state has settled.
        DispatchQueue.main.async {
            replayQueuedManagedSSHOffer()
        }
    }

    private func healWedgedSheetRequests(
        _ keys: Set<String>,
        scrollbackPaneIDs: Set<TerminalPane.ID>
    ) {
        // ponytail: healing sshWorkspaceConnect discards an already-consumed
        // managed-SSH offer (the setter consumed it from the store before the
        // sheet failed to mount); acceptable and logged — re-parking the offer
        // needs store support that doesn't exist yet.
        typealias Key = SheetWedgeRecoveryPolicy.RequestKey
        if keys.contains(Key.workspaceEdit) { workspaceEditRequest = nil }
        if keys.contains(Key.paneEdit) { paneEditRequest = nil }
        if keys.contains(Key.workspaceGroupCreate) { workspaceGroupCreateRequest = nil }
        if keys.contains(Key.remoteWorkspaceGroupCreate) { remoteWorkspaceGroupCreateRequest = nil }
        if keys.contains(Key.sshWorkspaceConnect) { sshWorkspaceConnectRequest = nil }
        if keys.contains(Key.workspaceGroupRename) { workspaceGroupRenameRequest = nil }
        if keys.contains(Key.quickSettings) { quickSettingsRequest = nil }
        for paneID in scrollbackPaneIDs {
            ghosttyRuntime.healScrollbackDumpSheetFlag(for: paneID)
        }
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

    // menu/palette entry points only ever show the panel, never dismiss it —
    // there's no keyboard-shortcut toggle affordance for this yet, so there's
    // nothing left that should call a dismiss-on-second-invocation `toggle`.
    private func showWorktreeManager() {
        guard !isAnySheetPresented, let worktreeManagerModel else { return }
        worktreeManagerController.show(
            model: worktreeManagerModel,
            relativeTo: NSApp.mainWindow ?? NSApp.keyWindow,
            presentingCreateForm: false
        )
    }

    // Distinct from `showWorktreeManager`: the palette's "Create Worktree…"
    // should always land in the create flow, even if the panel is already
    // open on something else — `show`, not `toggle`, so a second invocation
    // never dismisses it instead.
    private func presentWorktreeCreateForm() {
        guard !isAnySheetPresented, let worktreeManagerModel else { return }
        worktreeManagerController.show(
            model: worktreeManagerModel,
            relativeTo: NSApp.mainWindow ?? NSApp.keyWindow,
            presentingCreateForm: true
        )
    }

    private func presentFindInActivePane() {
        healSheetWedgeBeforeGatedCommand()
        guard !isAnySheetPresented,
            let session = sessionStore.selectedSession
        else {
            return
        }
        _ = ghosttyRuntime.presentSearch(in: session.activePaneID)
    }

    private func presentScrollbackDumpForActivePane() {
        healSheetWedgeBeforeGatedCommand()
        guard !isAnySheetPresented,
            let session = sessionStore.selectedSession
        else {
            return
        }
        _ = ghosttyRuntime.presentScrollbackDump(in: session.activePaneID)
    }

    /// Renders the active pane's agent session to Markdown and opens it beside
    /// the terminal.
    ///
    /// The render is a detached task because it is real work: up to 32 MiB read
    /// and converted, measured at 0.34 s for a 27 MB Claude session. Everything
    /// the render needs is copied out of the pane first, so a pane closing
    /// mid-render cannot be observed half-way — `openDocumentPane` fails closed
    /// on a session that is gone.
    private func openAgentTranscriptForActivePane() {
        // Same first line as Show Scrollback: this command is gated on
        // `isAnySheetPresented`, so a stale wedge would leave it silently dead.
        healSheetWedgeBeforeGatedCommand()
        guard !isAnySheetPresented,
            let session = sessionStore.selectedSession,
            let pane = session.layout.pane(id: session.activePaneID)
        else {
            return
        }
        let identity = AgentTranscriptPaneInputs.lookupIdentity(
            paneKind: pane.agentKind,
            liveSessionID: sessionStore.agentProviderSessionID(for: pane.id),
            lastEnded: sessionStore.lastEndedAgentTranscriptIdentity(for: pane.id)
        )
        let attempts = AgentTranscriptPaneInputs.resolutionAttempts(
            for: identity?.agentKind ?? pane.agentKind,
            integrations: appSettingsStore.agentIntegrations.value
        )
        guard !attempts.isEmpty else {
            let reason = AgentTranscriptPaneInputs.emptyLookupReason(
                paneKind: pane.agentKind,
                lastEndedKind: sessionStore.lastEndedAgentKind(for: pane.id)
            )
            showAgentTranscriptFailureAlert(.unavailable(reason))
            return
        }
        let executionPlan = pane.executionPlan
        let reportedSessionID = identity?.sessionID
        let sessionID = session.id
        let paneID = pane.id

        Task { @MainActor in
            // Matches the remote-Markdown document load: announce the start,
            // then the outcome. Failure keeps announcing through its alert.
            TerminalAccessibilityAnnouncer.announce(
                String(
                    localized: "Opening agent transcript.",
                    comment: "VoiceOver announcement when rendering a pane's agent transcript starts"
                )
            )
            let result = await Task.detached(priority: .userInitiated) {
                () -> Result<OpenedAgentTranscript, AgentTranscriptOpenFailure> in
                var firstFailure: AgentTranscriptOpenFailure?
                for attempt in attempts {
                    let outcome = AgentTranscriptOpener.open(
                        agentKind: attempt.kind,
                        executionPlan: executionPlan,
                        configHome: attempt.configHome,
                        reportedSessionID: reportedSessionID
                    )
                    if case .failure(let failure) = outcome {
                        firstFailure = firstFailure ?? failure
                        continue
                    }
                    return outcome
                }
                return .failure(firstFailure ?? .unavailable(.notFound))
            }.value

            switch result {
            case .success(let opened):
                guard
                    sessionStore.openDocumentPane(
                        fileURL: opened.fileURL,
                        in: sessionID,
                        associatedWith: paneID,
                        agentTranscriptIdentity: opened.identity
                    ) != nil
                else {
                    // The workspace went away while the transcript rendered.
                    // No alert — there is nothing left to act on, and the user
                    // closed it themselves — but silence would read as a dead
                    // command to anyone listening.
                    TerminalAccessibilityAnnouncer.announce(
                        String(
                            localized: "The workspace closed before the transcript could open.",
                            comment: "VoiceOver announcement when a rendered transcript has no workspace left to open into"
                        )
                    )
                    return
                }
                TerminalAccessibilityAnnouncer.announce(
                    String(
                        localized: "\(opened.identity.agentKind.displayName) transcript opened.",
                        comment: "VoiceOver announcement after a rendered agent transcript opens in a document tab"
                    )
                )
            case .failure(let failure):
                showAgentTranscriptFailureAlert(failure)
            }
        }
    }

    /// Stages the selected transcript's resume command into its terminal.
    ///
    /// The keyboard route to `DocumentPaneSendBar`'s Resume button, which
    /// refuses first responder (INT-562) and so cannot be reached with Full
    /// Keyboard Access or switch control. Both routes run the same ladder in
    /// `AgentTranscriptResumeStaging`, including its in-flight guard, so
    /// pressing the chord while the button is already probing cannot stage the
    /// payload twice.
    private func resumeSelectedTranscriptSession() {
        guard let session = sessionStore.selectedSession,
            let tab = selectedSessionTranscriptTab,
            let identity = tab.agentTranscriptIdentity
        else {
            // Say so rather than returning silently. The command stays enabled
            // precisely so this path is reachable — see `noTranscriptSelected`.
            showResumeUnavailableAlert(.noTranscriptSelected)
            return
        }
        Task { @MainActor in
            let outcome = await AgentTranscriptResumeStaging.stage(
                identity: identity,
                documentID: tab.id,
                layout: session.layout,
                integrations: appSettingsStore.agentIntegrations.value,
                foregroundComm: { ghosttyRuntime.foregroundComm(in: $0) },
                sendText: { ghosttyRuntime.sendText($0, toPane: $1) }
            )
            switch outcome {
            case .staged:
                TerminalAccessibilityAnnouncer.announce(
                    String(
                        localized: "Pasted into this transcript's terminal — press Return there to resume",
                        comment: "VoiceOver announcement after staging a resume command into the associated terminal"
                    ),
                    // `.high`, because staging changes the terminal's contents
                    // and the surface posts `.valueChanged` for that in the same
                    // breath. At `.medium` the content change won and a
                    // VoiceOver user heard the command text read out with no
                    // indication of what had happened to it — verified live.
                    // This sentence carries the whole staged-not-run
                    // distinction, which is the point of never auto-submitting.
                    priority: .high
                )
            case .alreadyStaging:
                // Not a denial — nothing is wrong — but silence here would be
                // this route's version of a dead command: the button's
                // disabled state and busy label never reach someone driving
                // the menu, and the probe can take seconds on a cold directory
                // walk. Mirror the button's busy sentence instead. The button
                // route speaks the identical sentence for the mirror-image
                // race (a click while the menu owns the probe).
                TerminalAccessibilityAnnouncer.announceResumeAlreadyChecking()
            case .unavailable(let reason):
                // An alert rather than the button's inline caption: this route
                // can run while the send bar is scrolled out of view, and a
                // denial nobody can see reads as a dead menu item. Same warning
                // shape as the transcript-open failure below.
                showResumeUnavailableAlert(reason)
            }
        }
    }

    private func showResumeUnavailableAlert(
        _ reason: AgentTranscriptResumeUnavailableReason
    ) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Can't Resume This Session",
            comment: "Alert title shown when a transcript's resume command cannot be staged.")
        alert.informativeText = DocumentPaneSendBar.resumeUnavailableDescription(for: reason)
        alert.alertStyle = .warning
        alert.addButton(
            withTitle: String(localized: "OK", comment: "Button title that dismisses an alert."))
        alert.runModal()
    }

    private func showAgentTranscriptFailureAlert(_ failure: AgentTranscriptOpenFailure) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "No Agent Transcript",
            comment: "Alert title shown when awesoMux cannot open a pane's agent transcript.")
        alert.informativeText = AgentTranscriptOpener.unavailableDescription(for: failure)
        alert.alertStyle = .warning
        alert.addButton(
            withTitle: String(localized: "OK", comment: "Button title that dismisses an alert."))
        alert.runModal()
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
        let sessionTitles = sessionStore.sidebarResolvedTitles()
        let workspaceTarget = sessionStore.selectedSession.map { session in
            PaletteWorkspaceActionTarget(
                sessionID: session.id,
                activePaneID: session.activePaneID,
                isSinglePane: session.layout.isSinglePane,
                selectedDocumentTabID: session.layout.firstDocumentGroup?.selectedTabID,
                displayedTitle: sessionTitles[session.id] ?? session.displayTitle()
            )
        }
        return PalettePresenter(
            sessionGroups: sessionStore.groups,
            sessionTitles: sessionTitles,
            commands: currentPaletteCommands(
                selectedWorkspaceTitle: workspaceTarget?.displayedTitle
            ),
            workspaceTarget: workspaceTarget,
            selectSession: { sessionID in
                guard let session = sessionStore.session(id: sessionID) else {
                    signalPaletteTargetUnavailable()
                    return false
                }
                sessionStore.selectedSessionID = sessionID
                appDelegate.surfacePrimaryWindow()
                requestTerminalFocus(sessionID: sessionID, paneID: session.activePaneID)
                return true
            },
            runCommand: { invocation in
                runPaletteCommand(invocation)
            },
            runQuickRun: { invocation, surface in
                runQuickRun(invocation, surface: surface)
            }
        )
    }

    private func runPaletteCommand(_ invocation: PaletteCommandInvocation) -> Bool {
        // Every selection-sensitive command, including the special workspace
        // cases below, must fail closed before it can act on its snapshot.
        guard
            invocation.canResolveAgainstCurrentSelection(
                sessionID: sessionStore.selectedSessionID,
                paneID: sessionStore.selectedSession?.activePaneID,
                documentTabID: sessionStore.selectedSession?.layout.firstDocumentGroup?.selectedTabID,
                isSinglePane: sessionStore.selectedSession?.layout.isSinglePane
            )
        else {
            signalPaletteTargetUnavailable()
            return false
        }

        if let target = invocation.workspaceTarget {
            switch invocation.commandID {
            case KeyboardShortcutCatalog.renameWorkspace.id:
                guard let session = sessionStore.session(id: target.sessionID) else {
                    signalPaletteTargetUnavailable()
                    return false
                }
                guard !isAnySheetPresented else {
                    signalPaletteTargetUnavailable()
                    return false
                }
                requestRenameWorkspace(session)
                return true
            case KeyboardShortcutCatalog.closeWorkspace.id:
                guard !isAnySheetPresented else {
                    signalPaletteTargetUnavailable()
                    return false
                }
                guard var session = sessionStore.session(id: target.sessionID) else {
                    signalPaletteTargetUnavailable()
                    return false
                }
                session.title = target.displayedTitle
                closeWorkspace(session)
                return true
            case KeyboardShortcutCatalog.clearWorkspace.id:
                guard var session = sessionStore.session(id: target.sessionID) else {
                    signalPaletteTargetUnavailable()
                    return false
                }
                guard !isAnySheetPresented else {
                    signalPaletteTargetUnavailable()
                    return false
                }
                session.title = target.displayedTitle
                clearWorkspace(session)
                return true
            default:
                break
            }
        }

        guard runPaletteCommand(id: invocation.commandID) else {
            signalPaletteTargetUnavailable()
            return false
        }
        return true
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
        _ invocation: PaletteQuickRunInvocation,
        surface: PaletteQuickRunCommitSurface
    ) -> Bool {
        guard
            invocation.canResolveAgainstCurrentSelection(
                sessionID: sessionStore.selectedSessionID,
                paneID: sessionStore.selectedSession?.activePaneID
            )
        else {
            signalPaletteTargetUnavailable()
            return false
        }
        let quickRun = invocation.result
        switch surface {
        case .toast:
            runQuickRunToast(
                quickRun,
                workingDirectoryURL: selectedWorkingDirectoryURL()
            )
        case .floatingPanel:
            runQuickRunInFloatingPanel(quickRun)
        case .newTab:
            runQuickRunInNewTab(quickRun)
        }
        return true
    }

    private func runQuickRunToast(
        _ quickRun: PaletteQuickRunResult,
        workingDirectoryURL: URL?
    ) {
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
                    cwd: workingDirectoryURL
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

    private func currentPaletteCommands(selectedWorkspaceTitle: String? = nil) -> [PaletteCommand] {
        sidebarCommandTargetAvailability.refresh()
        let presentedWorkspaceTitle =
            selectedWorkspaceTitle
            ?? sessionStore.selectedSession.flatMap {
                sessionStore.sidebarResolvedTitle(for: $0.id)
            }
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
            selectedWorkspaceTitle: presentedWorkspaceTitle,
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
                    selectionScope: .none,
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
                    selectionScope: .pane,
                    run: { [self] in
                        runCustomCommand(id: commandID)
                    }))
        }
        // One direct-apply row per checked-in layout preset, snapshotted at
        // palette-open time like the daemon rows above. The source session and
        // its anchor are captured HERE and baked into the command id, so a
        // stale row (selection or active pane changed while the palette sat
        // open) cannot silently resolve against a different session's
        // same-named preset when `runPaletteCommand` rebuilds this list fresh
        // at Enter time — the id simply won't be present in the rebuild and
        // the row is a no-op, matching every other id-keyed palette command.
        // The preset name and file are still re-validated and re-read at run
        // time (via `applyLayoutPreset`'s own load), so a preset deleted
        // between summon and Enter still fails with the normal load alert.
        if !isAnySheetPresented, let selected = sessionStore.selectedSession {
            let anchor = layoutPresetAnchorDirectory(for: selected)
            let sessionID = selected.id
            for presetName in LayoutPresetStore.listPresetNames(forWorkingDirectory: anchor) {
                commands.append(
                    PaletteCommand(
                        id: "applyLayoutPreset.\(sessionID).\(anchor).\(presetName)",
                        title: "Apply Layout: \(presetName)",
                        subtitle: "Layout preset",
                        keywords: ["layout", "preset", "split", "apply"],
                        shortcut: nil,
                        isEnabled: true,
                        selectionScope: .pane,
                        run: { [self] in
                            applyLayoutPreset(named: presetName, sessionID: sessionID, anchorDirectory: anchor)
                        }
                    ))
            }
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
            openAgentTranscript: openAgentTranscriptForActivePane,
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
            resumeAgentSession: resumeSelectedTranscriptSession,
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
            movePaneToNewWorkspace: moveActivePaneToNewWorkspace,
            returnPaneToSourceWorkspace: returnActivePaneToSourceWorkspace,
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
            openSettings: { openSettingsWindow() },
            openInIDE: openSelectedWorkspaceInIDE,
            showKeyboardCheatsheet: toggleKeyboardCheatsheet,
            openMarkdownFile: openMarkdownFilePanel,
            openSessionManager: toggleSessionManager,
            saveLayoutPreset: saveLayoutPresetForSelectedWorkspace,
            applyLayoutPreset: applyLayoutPresetViaPicker,
            openRecentLink: { value, sessionID, paneID in
                Task { @MainActor in
                    await GhosttyRuntime.openRecentLink(
                        value,
                        in: sessionID,
                        associatedWith: paneID,
                        sessionStore: sessionStore
                    )
                }
            },
            openWorktreeManager: showWorktreeManager,
            createWorktree: presentWorktreeCreateForm,
            openWorktree: showWorktreeManager,
            showWelcomeTour: { firstRunTourController.show() }
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

    // MARK: - Layout presets (INT-757)

    /// The directory the preset root is resolved FROM: the active pane's
    /// live-validated cwd — what the path bar shows — falling back to the
    /// session's declared cwd. A session created with a default cwd ("~") can
    /// silently anchor somewhere the user never looks; save/apply/list must all
    /// resolve from the location the user can SEE, and all from the same one.
    ///
    /// The active pane is excluded entirely when it carries a remote execution
    /// plan: a remote pane's `workingDirectory` is a path reported by the far
    /// side and may coincidentally exist locally, which would silently anchor
    /// presets in an unrelated local repository (INT-757 review).
    private func layoutPresetAnchorDirectory(for session: TerminalSession) -> String {
        let activeLocalDirectory: String? = session.activePane.flatMap { pane in
            guard pane.executionPlan.remoteTarget == nil else { return nil }
            return pane.workingDirectory
        }
        return WorkingDirectoryValidator.firstValidatedReportedDirectory(from: [
            activeLocalDirectory,
            session.workingDirectory,
        ]) ?? session.workingDirectory
    }

    private func saveLayoutPresetForSelectedWorkspace() {
        guard !isAnySheetPresented, let selected = sessionStore.selectedSession else { return }

        guard let intent = selected.layout.layoutIntent else {
            showLayoutPresetAlert(
                title: String(
                    localized: "No Layout to Save",
                    comment: "Alert title when the workspace has no preset-eligible panes."),
                message: String(
                    localized:
                        "This workspace has no local terminal panes, so there is no layout to save as a preset.",
                    comment: "Alert text when the workspace has no preset-eligible panes."))
            return
        }

        // Resolve the destination BEFORE asking for a name, so the dialog can
        // say exactly where the file will land — the root can differ from
        // where the user assumes (default-cwd sessions, worktrees).
        let anchorDirectory = layoutPresetAnchorDirectory(for: selected)
        guard let projectRoot = LayoutPresetStore.projectRoot(forWorkingDirectory: anchorDirectory)
        else {
            showLayoutPresetAlert(
                title: String(
                    localized: "Could Not Save Preset",
                    comment: "Alert title when saving a layout preset fails."),
                message: String(
                    localized: "The workspace's project folder could not be found.",
                    comment: "Failure reason when the layout preset project root cannot be resolved."))
            return
        }
        let destinationDirectory =
            projectRoot
            .appendingPathComponent(".awesomux/layouts", isDirectory: true)

        let alert = NSAlert()
        alert.messageText = String(
            localized: "Save Layout as Preset",
            comment: "Alert title for naming a new layout preset.")
        alert.informativeText = String(
            localized:
                "The preset will be saved to \(destinationDirectory.path), so it can be checked in and shared.",
            comment: "Alert text naming the folder the layout preset will be saved to.")
        alert.alertStyle = .informational
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = String(
            localized: "Preset name",
            comment: "Placeholder for the layout preset name field.")
        field.setAccessibilityLabel(
            String(
                localized: "Preset name",
                comment: "Accessibility label for the layout preset name field."))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(
            withTitle: String(localized: "Save", comment: "Button title that saves a layout preset."))
        alert.addButton(
            withTitle: String(localized: "Cancel", comment: "Button title that cancels saving a layout preset."))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let name = LayoutPresetStore.sanitizedPresetName(field.stringValue) else {
            showLayoutPresetAlert(
                title: String(
                    localized: "Invalid Preset Name",
                    comment: "Alert title for a rejected layout preset name."),
                message: String(
                    localized:
                        "Preset names use letters, numbers, spaces, hyphens, and underscores, up to 64 characters.",
                    comment: "Alert text describing the allowed layout preset name characters."))
            return
        }

        if LayoutPresetStore.presetFileExists(
            named: name,
            forWorkingDirectory: anchorDirectory
        ) {
            let overwrite = NSAlert()
            overwrite.messageText = String(
                localized: "Replace Existing Preset?",
                comment: "Alert title when saving over an existing layout preset.")
            overwrite.informativeText = String(
                localized: "A preset named “\(name)” already exists in this project.",
                comment: "Alert text when saving over an existing layout preset.")
            overwrite.alertStyle = .warning
            overwrite.addButton(
                withTitle: String(
                    localized: "Replace", comment: "Button title that overwrites an existing layout preset."))
            overwrite.addButton(
                withTitle: String(
                    localized: "Cancel", comment: "Button title that cancels overwriting a layout preset."))
            guard overwrite.runModal() == .alertFirstButtonReturn else { return }
        }

        do {
            let savedURL = try LayoutPresetStore.save(
                intent,
                named: name,
                forWorkingDirectory: anchorDirectory
            )
            postAccessibilityAnnouncement(
                String(
                    localized: "Saved layout preset \(name)",
                    comment: "VoiceOver announcement after saving a layout preset."))
            // Name the exact file that was written — the resolved root is not
            // always where the user assumes, and a silent success hides that.
            let confirmation = NSAlert()
            confirmation.messageText = String(
                localized: "Preset Saved",
                comment: "Alert title confirming a layout preset was saved.")
            confirmation.informativeText = savedURL.path
            confirmation.alertStyle = .informational
            confirmation.addButton(
                withTitle: String(localized: "OK", comment: "Button title that dismisses an alert."))
            confirmation.addButton(
                withTitle: String(
                    localized: "Reveal in Finder",
                    comment: "Button title that reveals the saved layout preset in Finder."))
            if confirmation.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([savedURL])
            }
        } catch {
            showLayoutPresetAlert(
                title: String(
                    localized: "Could Not Save Preset",
                    comment: "Alert title when saving a layout preset fails."),
                message: layoutPresetFailureMessage(for: error))
        }
    }

    private func applyLayoutPresetViaPicker() {
        guard !isAnySheetPresented, let selected = sessionStore.selectedSession else { return }

        // Captured once, before the modal alert runs, and reused verbatim at
        // apply time below — the picker must load from the anchor its list
        // came from, not whatever is selected by the time the alert closes.
        let anchor = layoutPresetAnchorDirectory(for: selected)
        let sessionID = selected.id
        let names = LayoutPresetStore.listPresetNames(forWorkingDirectory: anchor)
        guard !names.isEmpty else {
            showLayoutPresetAlert(
                title: String(
                    localized: "No Layout Presets Found",
                    comment: "Alert title when the project has no layout presets."),
                message: String(
                    localized:
                        "No presets were found under .awesomux/layouts for this project. Use “Save Layout as Preset…” to create one.",
                    comment: "Alert text when the project has no layout presets."))
            return
        }

        let alert = NSAlert()
        alert.messageText = String(
            localized: "Apply Layout Preset",
            comment: "Alert title for picking a layout preset to apply.")
        alert.informativeText = String(
            localized: "The preset opens as a new workspace in this project.",
            comment: "Alert text explaining that applying a preset creates a new workspace.")
        alert.alertStyle = .informational
        let popup = NSPopUpButton(
            frame: NSRect(x: 0, y: 0, width: 320, height: 26),
            pullsDown: false
        )
        popup.setAccessibilityLabel(
            String(
                localized: "Layout preset",
                comment: "Accessibility label for the layout preset picker popup."))
        for name in names {
            popup.addItem(withTitle: name)
        }
        alert.accessoryView = popup
        alert.addButton(
            withTitle: String(localized: "Apply", comment: "Button title that applies the selected layout preset."))
        alert.addButton(
            withTitle: String(localized: "Cancel", comment: "Button title that cancels applying a layout preset."))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let selectedIndex = popup.indexOfSelectedItem
        guard names.indices.contains(selectedIndex) else { return }
        applyLayoutPreset(named: names[selectedIndex], sessionID: sessionID, anchorDirectory: anchor)
    }

    /// `sessionID` and `anchorDirectory` are a snapshot taken by the caller at
    /// listing time (palette row build, or picker pre-alert) — never
    /// recomputed from `sessionStore.selectedSession` here. Recomputing would
    /// reintroduce the staleness this is guarding against: the session the
    /// user picked from could differ from whatever is selected by the time
    /// this runs, silently loading a same-named preset from another project.
    private func applyLayoutPreset(named name: String, sessionID: TerminalSession.ID, anchorDirectory: String) {
        guard let selected = sessionStore.session(id: sessionID) else { return }
        let workingDirectory = anchorDirectory

        do {
            let intent = try LayoutPresetStore.load(
                named: name,
                forWorkingDirectory: workingDirectory
            )
            let layout = intent.materialize(workingDirectory: workingDirectory)
            let session = TerminalSession(
                title: name,
                workingDirectory: workingDirectory,
                isTitleUserEdited: true,
                layout: layout
            )
            // New workspace lands next to the one it was applied from; the
            // default group is only a fallback for a groupless edge state.
            let groupName =
                sessionStore.groups.first { group in
                    group.sessions.contains { $0.id == selected.id }
                }?.name ?? appSettingsStore.workspaces.value.defaultGroup
            sessionStore.insertSession(session, groupName: groupName)
            appDelegate.surfacePrimaryWindow()
            postAccessibilityAnnouncement(
                String(
                    localized: "Applied layout preset \(name)",
                    comment: "VoiceOver announcement after applying a layout preset."))
        } catch {
            showLayoutPresetAlert(
                title: String(
                    localized: "Could Not Apply Preset",
                    comment: "Alert title when applying a layout preset fails."),
                message: layoutPresetFailureMessage(for: error))
        }
    }

    private func showLayoutPresetAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(
            withTitle: String(localized: "OK", comment: "Button title that dismisses an alert."))
        alert.runModal()
    }

    private func layoutPresetFailureMessage(for error: Error) -> String {
        switch error {
        case LayoutPresetStore.PresetError.invalidName:
            return String(
                localized: "The preset name is not valid.",
                comment: "Failure reason for an invalid layout preset name.")
        case LayoutPresetStore.PresetError.rootUnavailable:
            return String(
                localized: "The workspace's project folder could not be found.",
                comment: "Failure reason when the layout preset project root cannot be resolved.")
        case LayoutPresetStore.PresetError.directoryUnavailable:
            return String(
                localized:
                    "The .awesomux/layouts folder is missing or is not a plain folder. Symbolic links are not followed.",
                comment: "Failure reason when the layout preset folder is unusable.")
        case LayoutPresetStore.PresetError.notARegularFile:
            return String(
                localized: "The preset is not a plain file. Symbolic links are not followed.",
                comment: "Failure reason when a layout preset is not a regular file.")
        case LayoutPresetStore.PresetError.fileTooLarge:
            return String(
                localized: "The preset file is too large to be a layout preset.",
                comment: "Failure reason when a layout preset file exceeds the size cap.")
        case LayoutPresetStore.PresetError.nestingTooDeep:
            return String(
                localized: "The preset file is nested too deeply to be a valid layout.",
                comment: "Failure reason when a layout preset file fails the nesting scan.")
        case let WorkspaceLayoutPresetError.unsupportedVersion(version):
            return String(
                localized:
                    "The preset uses format version \(version), which this version of awesoMux does not support.",
                comment: "Failure reason for an unsupported layout preset format version.")
        case WorkspaceLayoutPresetError.layoutTooDeep:
            return String(
                localized: "The preset's layout has more nested splits than awesoMux supports.",
                comment: "Failure reason when a layout preset exceeds the split depth cap.")
        case WorkspaceLayoutPresetError.tooManyTerminals:
            return String(
                localized: "The preset's layout has more terminals than awesoMux supports.",
                comment: "Failure reason when a layout preset exceeds the terminal count cap.")
        case is DecodingError:
            return String(
                localized: "The preset file could not be read as a layout preset.",
                comment: "Failure reason for a malformed layout preset file.")
        default:
            return error.localizedDescription
        }
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

    private func openSettingsWindow(section: SettingsSectionID? = nil) {
        guard let openWindowAction else {
            assertionFailure("Open Settings requested before openWindow action was captured.")
            NSSound.beep()
            return
        }

        if let section { settingsSectionRequest.request(section) }
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

    private struct AboutCommands: Commands {
        let aboutPanelController: AboutPanelController

        var body: some Commands {
            // Replaces SwiftUI's default About item in the app menu. Presents
            // the controller-owned floating panel (not a Window scene) so
            // placement is deterministic — see AboutPanelController.
            CommandGroup(replacing: .appInfo) {
                Button("About awesoMux") {
                    aboutPanelController.show()
                }
            }
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
    let origin: SSHWorkspaceConnectOrigin
    let action: SSHWorkspaceConnectAction

    /// Builds the sheet request for a target whose offer was already consumed
    /// and allowed by `ManagedSSHOfferPolicy`. Consumption and policy live at
    /// the call site so the ask-free auto-connect path can branch on the same
    /// decision without re-reading the pane.
    @MainActor
    static func automaticOffer(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        target: RemoteTarget
    ) -> Self {
        Self(
            initialDestination: target.sshDestination,
            origin: .automaticOffer,
            action: .convertPane(sessionID: sessionID, paneID: paneID)
        )
    }

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
            origin: .explicitConversion,
            action: .convertPane(sessionID: session.id, paneID: session.activePaneID)
        )
    }
}

enum SSHWorkspaceConnectOrigin: Sendable {
    case automaticOffer
    case explicitConnection
    case explicitConversion

    var showsRememberActions: Bool {
        self == .automaticOffer
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
        Self.saveSessionIfRestoreEnabled(
            sessionStore,
            settings: appSettingsStore,
            failure: $sessionSaveFailure
        )
    }

    /// The same save, reachable without an `AwesoMuxApp` value. The store holds
    /// `onDisplayOnlyTitleWrite` for its whole lifetime, so that closure
    /// captures these three references rather than a copy of the App struct —
    /// a struct copy carries the Scene's `@State` boxes, one of which owns the
    /// store, and would close the cycle back onto it.
    @MainActor
    static func saveSessionIfRestoreEnabled(
        _ store: SessionStore,
        settings: AppSettingsStore,
        failure: Binding<SessionPersistence.RecoverySnapshotReplacementError?>
    ) {
        guard settings.general.value.restoreWorkspaces else {
            failure.wrappedValue = nil
            return
        }
        SessionPersistence.save(store) { result in
            record(result, in: failure)
        }
    }

    private func notificationPrimeInputs(isLaunchEvaluation: Bool) -> NotificationPrimePolicy.Inputs {
        let preferences = NotificationPreferences(config: appSettingsStore.notifications.value)
        return .init(
            // A group can hold `sessions: []`, so group count is not workspace
            // count — priming for a user with no terminal is the same class of
            // bug as priming at launch.
            hasEligibleSession: sessionStore.groups.contains { !$0.sessions.isEmpty },
            isLaunchEvaluation: isLaunchEvaluation,
            tourIsVisible: firstRunTourController.isVisible,
            tourReachedNotificationBeat: firstRunTourController.hasReachedNotificationBeat,
            anyChannelEnabled: preferences.shouldDeliverNeedsAttention()
                || preferences.shouldDeliverTurnDone(),
            requestInFlight: appDelegate.isNotificationRequestInFlight,
            // Deliberately permissive: the bridge re-checks real authorization
            // status asynchronously before showing anything. This policy's
            // job here is ordering (don't ask before the tour/workspace
            // exist), not authorization state.
            isNotDetermined: true)
    }

    private func handleSessionSaveResult(
        _ result: Result<Void, SessionPersistence.RecoverySnapshotReplacementError>
    ) {
        Self.record(result, in: $sessionSaveFailure)
    }

    private static func record(
        _ result: Result<Void, SessionPersistence.RecoverySnapshotReplacementError>,
        in failure: Binding<SessionPersistence.RecoverySnapshotReplacementError?>
    ) {
        switch result {
        case .success:
            failure.wrappedValue = nil
        case let .failure(error):
            guard error != .warningNotActive else { return }
            failure.wrappedValue = error
        }
    }

    /// Installed once, on the store the Scene owns: a display-only title write
    /// is deliberately invisible to `.onChange(of: sessionStore.groups)`
    /// (issue #311), so it schedules its own save here instead.
    private func installDisplayOnlyTitleSaveHandler() {
        sessionStore.onDisplayOnlyTitleWrite = {
            [weak sessionStore, appSettingsStore, failure = $sessionSaveFailure] in
            guard let sessionStore else { return }
            Self.saveSessionIfRestoreEnabled(sessionStore, settings: appSettingsStore, failure: failure)
        }
    }

    /// The setting's two edges are not symmetric. Turning it ON is a chance to
    /// tell the user that the snapshot on disk is unreadable — `save` validates
    /// regardless, but has no return path to the UI. Turning it OFF has to drop
    /// a write the debouncer already captured, which no longer re-reads the
    /// setting, and re-arm validation so a later opt-in re-inspects a file that
    /// may have changed while nothing was watching it.
    private func restoreWorkspacesSettingDidChange(isEnabled: Bool) {
        guard isEnabled else {
            SessionPersistence.restoreWorkspacesDidTurnOff()
            return
        }
        guard !isRecoveryReplacementInProgress else { return }
        let warning = SessionPersistence.validateSnapshotForNewlyEnabledRestore()
        // Only a warning that actually paused saving is worth raising. The
        // restored store is discarded, so a sanitization notice would be
        // describing workspaces the user is never going to see.
        //
        // Deliberately no catch-up save on the clean path. Launching with
        // restore off builds a bare `SessionStore`, so saving here would write
        // that empty store over a healthy saved session inside the debounce
        // window — the exact clobber `saveSessionIfRestoreEnabled`'s own doc
        // comment exists to prevent. The next real mutation persists.
        guard warning?.preventsInitialSave == true else { return }
        recoveryWarning = warning
        recoveryWarningAppearedMidSession = true
        didPresentRecoveryWarning = false
        // Hopped off the view update: `presentRecoveryWarningIfNeeded` spins a
        // nested modal runloop, and the replacement path re-enters `runModal` in
        // a retry loop. Running that inside a SwiftUI change body is a wedge.
        Task { @MainActor in
            presentRecoveryWarningIfNeeded()
        }
    }

    private func presentRecoveryWarningIfNeeded() {
        guard let warning = recoveryWarning, !didPresentRecoveryWarning else {
            return
        }

        didPresentRecoveryWarning = true

        let decision: RecoveryWarningDecision
        switch warning.kind {
        case .archivedSnapshot:
            decision = presentArchiveRecoveryWarning(warning)
        case .snapshotConflict:
            decision = presentSnapshotConflictWarning(warning)
        case .sanitizedRestore:
            decision = presentSanitizedRestoreWarning(warning)
        }

        guard decision == .replaceSavedFile else {
            if shouldAcknowledgeRecoveryWarning(
                decision: decision,
                allowsAutomaticWritesAfterAcknowledgement:
                    warning.allowsAutomaticWritesAfterAcknowledgement
            ) {
                if SessionPersistence.acknowledgeRecoveryWarning(
                    warning,
                    thenSaving: appSettingsStore.general.value.restoreWorkspaces
                        ? sessionStore : nil,
                    completion: handleSessionSaveResult
                ) {
                    recoveryWarning = nil
                }
            } else if !warning.preventsInitialSave {
                recoveryWarning = nil
            }
            return
        }

        beginRecoveryReplacement(warning)
    }

    private func beginRecoveryReplacement(
        _ warning: SessionPersistence.SessionRecoveryWarning
    ) {
        guard !isRecoveryReplacementInProgress else { return }
        recoveryReplacementSuccessID = nil
        isRecoveryReplacementInProgress = true
        postAccessibilityAnnouncement(
            String(
                localized: "Replacing saved workspace data",
                comment: "VoiceOver announcement when a recovery replacement starts"
            )
        )
        Task { @MainActor in
            await completeRecoveryReplacement(warning)
            isRecoveryReplacementInProgress = false
        }
    }

    private func completeRecoveryReplacement(
        _ warning: SessionPersistence.SessionRecoveryWarning
    ) async {
        var replacementDecision = RecoveryWarningDecision.replaceSavedFile
        while replacementDecision == .replaceSavedFile {
            switch await SessionPersistence.replaceSnapshotAfterRecovery(
                with: sessionStore,
                warning: warning,
                catchUpSaveCompletion: handleSessionSaveResult
            ) {
            case .success:
                recoveryWarning = nil
                showRecoveryReplacementSuccess()
                return
            case let .failure(error):
                replacementDecision = presentRecoveryReplacementFailure(error)
            }
        }
    }

    private func showRecoveryReplacementSuccess() {
        let successID = UUID()
        recoveryReplacementSuccessID = successID
        postAccessibilityAnnouncement(
            String(
                localized: "Saved workspace data replaced",
                comment: "VoiceOver announcement after a recovery replacement succeeds"
            )
        )
        Task { @MainActor in
            try? await ContinuousClock().sleep(for: .seconds(5))
            if recoveryReplacementSuccessID == successID {
                recoveryReplacementSuccessID = nil
            }
        }
    }

    private func presentRecoveryReplacementFailure(
        _ error: SessionPersistence.RecoverySnapshotReplacementError
    ) -> RecoveryWarningDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Couldn't replace saved workspace data",
            comment: "Title for a failed explicit session recovery replacement"
        )
        switch error {
        case .snapshotTooLarge:
            alert.informativeText = String(
                localized:
                    "The workspaces currently open in awesoMux are too large to save safely. The existing saved file was kept and automatic session saving remains paused. Close or simplify workspaces, then choose Review Recovery Options in the main window to try again.",
                comment: "Recovery replacement failure shown when current workspace data exceeds the snapshot size limit"
            )
        case .warningNotActive, .writeFailed:
            alert.informativeText = String(
                localized:
                    "awesoMux couldn't replace the saved workspace file. The existing file was kept and automatic session saving remains paused.",
                comment: "Recovery replacement failure shown after an owner-only snapshot write fails"
            )
        }
        if recoveryReplacementFailurePresentation(for: error) == .reviewAfterStateChange {
            alert.addButton(
                withTitle: String(
                    localized: "Keep Saved File",
                    comment: "Safe action after an oversized session recovery replacement"
                )
            )
            alert.buttons[0].keyEquivalent = "\r"
            alert.runModal()
            return .keepSavedFile
        }

        alert.addButton(
            withTitle: String(
                localized: "Keep Saved File",
                comment: "Safe action after a failed session recovery replacement"
            )
        )
        alert.addButton(
            withTitle: String(
                localized: "Try Replace Again",
                comment: "Retry action after a failed session recovery replacement"
            )
        )
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].hasDestructiveAction = true

        switch alert.runModal() {
        case .alertSecondButtonReturn:
            return .replaceSavedFile
        default:
            return .keepSavedFile
        }
    }

    private func reviewRecoveryWarning() {
        guard
            !isRecoveryReplacementInProgress,
            let didPresent = RecoveryWarningPresentationPolicy.didPresentAfterReviewRequest(
                hasWarning: recoveryWarning != nil
            )
        else {
            return
        }
        didPresentRecoveryWarning = didPresent
        presentRecoveryWarningIfNeeded()
    }

    private func presentArchiveRecoveryWarning(
        _ warning: SessionPersistence.SessionRecoveryWarning
    ) -> RecoveryWarningDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText =
            recoveryWarningAppearedMidSession
            ? String(
                localized: "Couldn't read your saved workspace file",
                comment: "Title for the session snapshot recovery warning raised mid-session"
            )
            : String(
                localized: "Couldn't reopen your last workspaces",
                comment: "Title for the session snapshot recovery warning"
            )
        let wasArchived = warning.archivedSnapshotURL != nil && warning.archiveError == nil
        switch (recoveryWarningAppearedMidSession, wasArchived) {
        case (true, true):
            alert.informativeText = String(
                localized:
                    "awesoMux checked the saved workspace file and couldn't read it. An exact copy was archived for recovery. Your open workspaces are untouched, but automatic session saving is paused so the saved file is not replaced without your approval.",
                comment: "Recovery warning shown mid-session after unreadable workspace data was archived"
            )
        case (true, false):
            alert.informativeText = String(
                localized:
                    "awesoMux checked the saved workspace file and couldn't read it, and couldn't archive a copy either, so it was left untouched. Your open workspaces are unaffected. Automatic session saving is paused. Keep that file, or explicitly replace it with the workspaces currently open in awesoMux.",
                comment: "Recovery warning shown mid-session when unreadable workspace data could not be archived"
            )
        case (false, true):
            alert.informativeText = String(
                localized:
                    "We couldn't read your saved workspace data, so awesoMux opened with fresh workspaces. An exact copy was archived for recovery. Automatic session saving is paused so the live saved file is not replaced without your approval.",
                comment: "Recovery warning shown after unreadable workspace data was archived"
            )
        case (false, false):
            alert.informativeText = String(
                localized:
                    "We couldn't read your saved workspace data, so awesoMux opened with fresh workspaces and left the live saved file untouched. Automatic session saving is paused. Keep that file, or explicitly replace it with the workspaces currently open in awesoMux.",
                comment: "Recovery warning shown when unreadable workspace data could not be archived"
            )
        }

        alert.accessoryView = recoveryPathAccessoryField(for: warning)

        return runBlockedRecoveryAlert(alert, warning: warning)
    }

    private func presentSnapshotConflictWarning(
        _ warning: SessionPersistence.SessionRecoveryWarning
    ) -> RecoveryWarningDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText =
            recoveryWarningAppearedMidSession
            ? String(
                localized: "Saved workspace data changed while awesoMux was reading it",
                comment: "Title for a session snapshot path-conflict warning raised mid-session"
            )
            : String(
                localized: "Saved workspace data changed during restore",
                comment: "Title for a session snapshot path-conflict warning"
            )
        let wasArchived = warning.archivedSnapshotURL != nil && warning.archiveError == nil
        switch (recoveryWarningAppearedMidSession, wasArchived) {
        case (true, true):
            alert.informativeText = String(
                localized:
                    "Something replaced the saved workspace file while awesoMux was checking it. awesoMux preserved the version it had already read in a recovery file. Your open workspaces are untouched, but automatic session saving is paused. Keep the live file, or explicitly replace it with the workspaces currently open in awesoMux.",
                comment:
                    "Recovery warning shown mid-session when saved workspace data changed while being read and the opened bytes were archived"
            )
        case (true, false):
            alert.informativeText = String(
                localized:
                    "Something replaced the saved workspace file while awesoMux was checking it, and awesoMux could not preserve the version it had already read. Your open workspaces are untouched, but automatic session saving is paused. Keep the live file, or explicitly replace it with the workspaces currently open in awesoMux.",
                comment:
                    "Recovery warning shown mid-session when saved workspace data changed while being read and the opened bytes could not be archived"
            )
        case (false, true):
            alert.informativeText = String(
                localized:
                    "awesoMux reopened the version it had already read and preserved those bytes in a recovery file. The live saved file changed during restore, so automatic session saving is paused. Keep the live file, or explicitly replace it with the workspaces currently open in awesoMux.",
                comment: "Recovery warning shown when saved workspace data changed during restore and the opened bytes were archived"
            )
        case (false, false):
            alert.informativeText = String(
                localized:
                    "The live saved file changed while awesoMux was reopening it, and awesoMux could not preserve the version it had already read. Automatic session saving is paused. Keep the live file, or explicitly replace it with the workspaces currently open in awesoMux.",
                comment:
                    "Recovery warning shown when saved workspace data changed during restore and the opened bytes could not be archived"
            )
        }
        alert.accessoryView = recoveryPathAccessoryField(for: warning)

        return runBlockedRecoveryAlert(alert, warning: warning)
    }

    private func runBlockedRecoveryAlert(
        _ alert: NSAlert,
        warning: SessionPersistence.SessionRecoveryWarning
    ) -> RecoveryWarningDecision {
        alert.addButton(
            withTitle: String(
                localized: "Keep Saved File",
                comment: "Safe action that leaves conflicted session snapshot data untouched"
            )
        )
        alert.addButton(
            withTitle: String(
                localized: "Replace With Current Workspaces",
                comment: "Destructive action that replaces conflicted session snapshot data"
            )
        )
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].hasDestructiveAction = true
        if warning.archivedSnapshotURL != nil {
            alert.addButton(
                withTitle: String(
                    localized: "Show in Finder",
                    comment: "Action that reveals a session snapshot recovery archive"
                )
            )
            alert.addButton(
                withTitle: String(
                    localized: "Copy Path",
                    comment: "Action that copies a session snapshot recovery archive path"
                )
            )
        }

        return resolveBlockedRecoveryWarningDecision(
            runModal: { alert.runModal() },
            showArchive: {
                guard let url = warning.archivedSnapshotURL, isSafeRecoveryArchiveURL(url) else {
                    return
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            copyPath: {
                guard let path = warning.archivedSnapshotURL?.path else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        )
    }

    private func presentSanitizedRestoreWarning(
        _ warning: SessionPersistence.SessionRecoveryWarning
    ) -> RecoveryWarningDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some workspace data was adjusted"
        // Mid-session the restored store is discarded — only the warning
        // survives — so "reopened your saved workspaces" would describe
        // workspaces the user is never shown.
        var informativeLines = [
            recoveryWarningAppearedMidSession
                ? String(
                    localized:
                        "awesoMux checked the saved workspace file and found data that could not be restored safely. Your open workspaces are untouched.",
                    comment: "Lead line for a sanitized-restore warning raised mid-session"
                )
                : String(
                    localized:
                        "awesoMux reopened your saved workspaces, but cleaned up data that could not be restored safely.",
                    comment: "Lead line for a sanitized-restore warning raised at launch"
                )
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

        if warning.preventsInitialSave {
            return runBlockedRecoveryAlert(alert, warning: warning)
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
        return .dismissed
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
