import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import os
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "lifecycle"
    )
    var sessionStore: SessionStore?
    private var appSettingsStore: AppSettingsStore?
    private var ghosttyRuntime: GhosttyRuntime?
    private var floatingPanelController: TerminalPanelController?
    private var popUpTerminalController: TerminalPanelController?
    /// Opens SwiftUI `Window` scenes. Injected via `bind(_:)` because opening a
    /// scene needs an `OpenWindowAction` captured from a view's environment —
    /// the delegate has no environment of its own.
    private var openSettings: (() -> Void)?
    private var openPrimaryWindow: (() -> Void)?
    private let notificationBridge = WorkspaceNotificationBridge()
    private lazy var menuBarMiniStatusItemController = MenuBarMiniStatusItemController(
        primaryAction: { [weak self] in
            self?.menuBarStatusItemPrimaryClick()
        },
        menuProvider: { [weak self] in
            self?.makeDockCommandMenu()
        }
    )
    /// Deep link from a notification click that arrived before `bind(...)`
    /// gave us a session store (cold launch via notification). Replayed and
    /// cleared in `bind`.
    private var pendingDeepLinkSessionID: TerminalSession.ID?
    private var notificationTracker = WorkspaceNotificationTracker()
    private var dockBounceTracker = WorkspaceDockBounceTracker()
    private var workspaceAnnouncementTracker = WorkspaceAttentionAnnouncementTracker()
    private var pendingWorkspaceAnnouncements: [WorkspaceAttentionAnnouncementTracker.Announcement] = []
    private var pendingWorkspaceAnnouncementTask: Task<Void, Never>?
    private var remoteConnectivityObserver: RemoteConnectivityObserver?
    private var lastDockBadgeTotal = 0
    private var pendingDockBadgeAnnouncement: Task<Void, Never>?
    private var focusObservers: [NSObjectProtocol] = []
    private var didBindOnce = false
    private var isQuitRiskAlertPresented = false
    private var lastTerminateTrigger: String = "nil"
    private var didClampInitialWindowFrame = false
    private var didInstallPrimaryWindowFrameSaver = false
    /// Coalesce window-frame saves over a live-resize/move stream — only persist
    /// the settled frame once the stream goes quiet.
    private static let frameSaveDebounceInterval: TimeInterval = 0.2
    private static let systemQuitWarningTimeout: TimeInterval = 4.0
    private var pendingPrimaryWindowFrameSave: DispatchWorkItem?
    private var pendingSystemQuitWarningTimeout: DispatchWorkItem?
    private weak var primaryWindowForFrameSave: NSWindow?
    private var isSystemQuitWarningPresented = false
    private let windowOrderDiagnostics = WindowOrderDiagnostics()

    /// True when `applicationShouldTerminate` is firing as part of a system
    /// logout / restart / shutdown sequence (rather than a user-initiated
    /// Cmd-Q / menu Quit / Dock Quit). We detect this via the AppleEvent that
    /// triggered termination — `kAEQuitReason` is set to one of the system
    /// reason codes. `NSApp.currentEvent` cannot tell these apart.
    private var isSystemInitiatedQuit: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let reasonDescriptor = event.attributeDescriptor(forKeyword: kAEQuitReason)
        else {
            return false
        }
        switch reasonDescriptor.enumCodeValue {
        case kAELogOut, kAEReallyLogOut, kAEShowRestartDialog,
             kAEShowShutdownDialog, kAERestart, kAEShutDown:
            return true
        default:
            return false
        }
    }

    /// Dock-click reactivation. When the user clicks the awesoMux Dock
    /// icon while the app is running but has no visible windows (typical
    /// after they closed the only window without quitting), macOS calls
    /// this. The stable primary scene id lets the delegate reopen the
    /// singleton primary `Window` through the same captured action used by
    /// Dock-menu workspace commands.
    ///
    /// We intentionally do NOT pop the recently-closed buffer here.
    /// Clicking the Dock icon means "give me my app back," not "restore
    /// the workspace I last closed." Auto-popping would surprise the user
    /// every time they click Dock after closing a window — the buffer is
    /// reachable from inside the new window via ⌘+⇧+T, which is the right
    /// place for an explicit reopen gesture. Matches Safari's Dock-icon
    /// behavior (Safari does NOT auto-reopen the last closed tab on Dock
    /// click; Cmd+Shift+T inside the window does).
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        WindowOrderDiagnostics.logApplicationReopen(hasVisibleWindows: hasVisibleWindows)
        guard !hasVisibleWindows else { return true }
        // hasVisibleWindows is also false when the only primary window is
        // miniaturized; surfacePrimaryWindow prefers that window (and
        // deminiaturizes it) before falling back to opening the scene.
        surfacePrimaryWindow()
        return false
    }

    // MARK: - Dock / menu bar command menu (INT-633, INT-635)

    /// Right-click Dock menu. Rebuilt on every request so it always reflects the
    /// current recents. Every item targets the delegate (which holds the stores)
    /// or `NSApp`, never the key window, so the actions fire while the app is
    /// backgrounded without the user focusing the main window first. Items whose
    /// dependencies are not yet bound are disabled rather than crashing.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        makeDockCommandMenu()
    }

    /// Shared command set for the Dock right-click menu and the menu-bar
    /// mini-status item's secondary click. The Dock appends its own native Quit
    /// item; the status item intentionally mirrors only awesoMux-owned commands.
    private func makeDockCommandMenu() -> NSMenu {
        let menu = NSMenu()
        // Own item enablement explicitly: NSMenu auto-enables any item whose
        // target responds to its action, which would override the pre-bind /
        // empty-recents disabled states below. (Mirrors PaneDragAndDrop.)
        menu.autoenablesItems = false

        // Open workspaces first, per the standard macOS Dock-menu pattern
        // (running documents/windows sit above app-level actions). Empty when
        // no window has opened yet or the store isn't bound — skip the section
        // and its separator entirely so the menu never shows a dangling divider.
        let openWorkspaces = makeOpenWorkspaceItems()
        if !openWorkspaces.isEmpty {
            openWorkspaces.forEach(menu.addItem)
            menu.addItem(.separator())
        }

        let newWorkspace = NSMenuItem(
            title: String(
                localized: "New Workspace",
                comment: "Dock right-click menu item that opens a new workspace."
            ),
            action: #selector(dockNewWorkspace),
            keyEquivalent: ""
        )
        newWorkspace.target = self
        newWorkspace.isEnabled = sessionStore != nil && appSettingsStore != nil
        menu.addItem(newWorkspace)

        let recents = NSMenuItem(
            title: String(
                localized: "Recent Workspaces",
                comment: "Dock right-click menu item whose submenu lists recently closed workspaces to reopen."
            ),
            action: nil,
            keyEquivalent: ""
        )
        let recentsSubmenu = makeRecentWorkspacesSubmenu()
        recents.submenu = recentsSubmenu
        // Disable the parent when nothing is reopenable so it reads as
        // unavailable rather than opening an empty flyout.
        recents.isEnabled = recentsSubmenu.items.contains { $0.isEnabled }
        menu.addItem(recents)

        let floatingPanel = NSMenuItem(
            title: String(
                localized: "Show Floating Panel",
                comment: "Dock right-click menu item that shows the floating terminal panel."
            ),
            action: #selector(dockShowFloatingPanel),
            keyEquivalent: ""
        )
        floatingPanel.target = self
        floatingPanel.isEnabled = sessionStore != nil
            && ghosttyRuntime != nil
            && appSettingsStore != nil
            && floatingPanelController != nil
        menu.addItem(floatingPanel)

        let popUpTerminal = NSMenuItem(
            title: String(
                localized: "Show Terminal Companion",
                comment: "Dock right-click menu item that shows the Terminal Companion."
            ),
            action: #selector(dockShowPopUpTerminal),
            keyEquivalent: ""
        )
        popUpTerminal.target = self
        popUpTerminal.isEnabled = sessionStore != nil
            && ghosttyRuntime != nil
            && appSettingsStore != nil
            && popUpTerminalController != nil
        menu.addItem(popUpTerminal)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: String(
                localized: "Settings…",
                comment: "Dock right-click menu item that opens the Settings window."
            ),
            action: #selector(dockOpenSettings),
            keyEquivalent: ""
        )
        settings.target = self
        settings.isEnabled = openSettings != nil
        menu.addItem(settings)

        // No custom Quit item: macOS appends a native Quit to every Dock menu,
        // and it already routes through applicationShouldTerminate — so the
        // quit-risk confirmation gate is preserved without us adding one.
        return menu
    }

    func syncMenuBarMiniStatusItem() {
        menuBarMiniStatusItemController.update(
            isEnabled: appSettingsStore?.general.value.showMenuBarMiniStatus ?? false,
            hasWorkspaceNeedingInput: sessionStore?.hasWorkspaceNeedingInputForMenuBar == true
        )
    }

    /// Live workspaces in sidebar order (groups in order, sessions within),
    /// each selecting its workspace and surfacing the window on click. The
    /// currently-selected workspace carries a checkmark. Empty when the store
    /// isn't bound yet.
    private func makeOpenWorkspaceItems() -> [NSMenuItem] {
        guard let sessionStore else { return [] }
        return DockRecentWorkspaceMenu.openWorkspaceRows(
            groups: sessionStore.groups,
            pinnedSessionIDs: sessionStore.pinnedSessionIDs,
            activeID: sessionStore.selectedSessionID
        ).map { row in
            let item = NSMenuItem(
                title: row.title,
                action: #selector(dockSelectOpenWorkspace(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = DockOpenWorkspaceToken(sessionID: row.sessionID)
            item.state = row.isActive ? .on : .off
            return item
        }
    }

    private func makeRecentWorkspacesSubmenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let recents = sessionStore?.recentWorkspaces() ?? []
        guard !recents.isEmpty else {
            let empty = NSMenuItem(
                title: String(
                    localized: "No Recent Workspaces",
                    comment: "Placeholder shown in the Dock menu's Recent Workspaces submenu when nothing has been closed recently."
                ),
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            submenu.addItem(empty)
            return submenu
        }
        for workspace in recents {
            let item = NSMenuItem(
                title: DockRecentWorkspaceMenu.displayTitle(for: workspace),
                action: #selector(dockReopenRecentWorkspace(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = DockRecentWorkspaceToken(workspace: workspace)
            submenu.addItem(item)
        }
        return submenu
    }

    @objc
    private func dockNewWorkspace() {
        guard let sessionStore, let appSettingsStore else {
            NSSound.beep()
            return
        }
        sessionStore.addSession(groupName: appSettingsStore.workspaces.value.defaultGroup)
        surfacePrimaryWindow()
    }

    @objc
    private func dockReopenRecentWorkspace(_ sender: NSMenuItem) {
        guard let sessionStore,
              let token = sender.representedObject as? DockRecentWorkspaceToken else {
            NSSound.beep()
            return
        }
        // The entry may have been reopened or aged out since the menu was built;
        // reopen returns nil then. Only surface the window on an actual reopen so
        // success and no-op don't look identical to the user.
        guard sessionStore.reopen(token.workspace) != nil else {
            NSSound.beep()
            return
        }
        surfacePrimaryWindow()
    }

    @objc
    private func dockSelectOpenWorkspace(_ sender: NSMenuItem) {
        guard let sessionStore,
              let token = sender.representedObject as? DockOpenWorkspaceToken else {
            NSSound.beep()
            return
        }
        // The workspace may have closed since the menu was built, and the
        // store does NOT validate direct selectedSessionID assignments — a
        // stale id would render the no-selection state. Mirror the recents
        // handler: beep and keep the current selection instead.
        guard sessionStore.session(id: token.sessionID) != nil else {
            NSSound.beep()
            return
        }
        // Same select path the command palette / notification deep-link use;
        // setting selectedSessionID drives which workspace's panes render.
        sessionStore.selectedSessionID = token.sessionID
        surfacePrimaryWindow()
    }

    @objc
    private func dockShowFloatingPanel() {
        guard let sessionStore,
              let ghosttyRuntime,
              let appSettingsStore,
              let floatingPanelController else {
            NSSound.beep()
            return
        }
        floatingPanelController.show(
            relativeTo: NSApp.mainWindow ?? NSApp.keyWindow,
            sessionStore: sessionStore,
            ghosttyRuntime: ghosttyRuntime,
            appSettingsStore: appSettingsStore
        )
    }

    @objc
    private func dockShowPopUpTerminal() {
        guard let sessionStore,
              let ghosttyRuntime,
              let appSettingsStore,
              let popUpTerminalController else {
            NSSound.beep()
            return
        }
        surfacePrimaryWindow()
        showPopUpTerminalFromDock(
            sessionStore: sessionStore,
            ghosttyRuntime: ghosttyRuntime,
            appSettingsStore: appSettingsStore,
            controller: popUpTerminalController
        )
    }

    private func showPopUpTerminalFromDock(
        sessionStore: SessionStore,
        ghosttyRuntime: GhosttyRuntime,
        appSettingsStore: AppSettingsStore,
        controller: TerminalPanelController,
        attempt: Int = 0
    ) {
        guard let primaryWindow = NSApp.awesoMuxPrimaryContentWindow else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.showPopUpTerminalFromDock(
                        sessionStore: sessionStore,
                        ghosttyRuntime: ghosttyRuntime,
                        appSettingsStore: appSettingsStore,
                        controller: controller,
                        attempt: attempt + 1
                    )
                }
            } else {
                // The Dock path surfaced the primary window above; if it never
                // materialized, showing an unattached companion would strand it
                // with no parent observers once the window does appear. Fail
                // closed like the other Dock guards.
                NSSound.beep()
            }
            return
        }
        controller.show(
            relativeTo: primaryWindow,
            sessionStore: sessionStore,
            ghosttyRuntime: ghosttyRuntime,
            appSettingsStore: appSettingsStore
        )
    }

    private func menuBarStatusItemPrimaryClick() {
        dockShowFloatingPanel()
    }

    @objc
    private func dockOpenSettings() {
        guard let openSettings else {
            NSSound.beep()
            return
        }
        openSettings()
    }

    /// Workspace-selection shortcuts (⌘1…⌘9, ⇧⌘[ / ⇧⌘]) leak through the
    /// floating terminal panel; unconditional surfacing would let them steal
    /// key status from the panel mid-use. Only surface when no primary window
    /// is on screen — the zero-window/miniaturized case INT-718 fixes.
    func surfacePrimaryWindowIfNotVisible(
        caller: StaticString = #function,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) {
        if let window = NSApp.windows.first(where: { $0.isAwesoMuxPrimaryContentWindow }),
           window.isVisible, !window.isMiniaturized {
            WindowOrderDiagnostics.logSurfacePrimaryWindow(
                event: "surface-primary-window-skipped-visible",
                caller: caller,
                fileID: fileID,
                line: line
            )
            return
        }
        surfacePrimaryWindow(caller: caller, fileID: fileID, line: line)
    }

    /// Bring the app forward and surface the singleton primary content window
    /// after an app-level workspace action, opening it first when the app is
    /// alive with no visible primary window.
    func surfacePrimaryWindow(
        caller: StaticString = #function,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) {
        WindowOrderDiagnostics.logSurfacePrimaryWindow(
            event: "surface-primary-window-begin",
            caller: caller,
            fileID: fileID,
            line: line
        )
        NSApp.activate(ignoringOtherApps: true)
        let primaryWindow = NSApp.windows
            .first(where: { $0.isAwesoMuxPrimaryContentWindow })
            .map { window in
                PrimaryWindowSurfaceWindow(
                    isMiniaturized: window.isMiniaturized,
                    deminiaturize: { window.deminiaturize(nil) },
                    orderFront: { window.makeKeyAndOrderFront(nil) }
                )
            }
        PrimaryWindowSurfacer.surface(
            window: primaryWindow,
            openPrimaryWindow: openPrimaryWindow,
            beep: { NSSound.beep() }
        )
        WindowOrderDiagnostics.logSurfacePrimaryWindow(
            event: "surface-primary-window-end",
            caller: caller,
            fileID: fileID,
            line: line
        )
    }

    /// Both `shouldSaveApplicationState` and `shouldRestoreApplicationState`
    /// read the same hidden default. awesoMux restores workspaces/sessions
    /// through `SessionPersistence`; AppKit persistent window restoration can
    /// resurrect stale SwiftUI window identifiers after a crash and leave the
    /// app running with no visible window. Keep the hidden default off until
    /// the persistence story deliberately grows AppKit window restoration.
    private var appKitStateRestorationEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.appKitStateRestorationEnabled)
    }

    func application(
        _ application: NSApplication,
        shouldSaveApplicationState coder: NSCoder
    ) -> Bool {
        appKitStateRestorationEnabled
    }

    func application(
        _ application: NSApplication,
        shouldRestoreApplicationState coder: NSCoder
    ) -> Bool {
        appKitStateRestorationEnabled
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowOrderDiagnostics.start()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        ShortcutDiagnostics.log(
            "stage=applicationDidFinishLaunching applicationClass=\(NSStringFromClass(type(of: NSApp!))) customApplication=\(NSApp is AwesoMuxApplication)"
        )
        #if DEBUG
        if !(NSApp is AwesoMuxApplication) {
            assertionFailure("Expected NSApp to be AwesoMuxApplication for app-level shortcuts.")
        }
        #endif

        // Bug 1 fix: opt the foreground app into banner + sound presentation.
        // macOS otherwise quietly stuffs notifications into the Notification
        // Center list while awesoMux is frontmost — the user only notices
        // them when something else takes focus and surfaces the queue.
        UNUserNotificationCenter.current().delegate = self

        // Sweep stale temp PNGs from prior sessions in the background. Cleanup
        // runs here exactly once per launch instead of on every image paste —
        // the per-paste version showed up as a main-thread directory walk.
        ClipboardPasteImageStore.scheduleCleanup()

        installInitialWindowFrameClamp()
    }

    /// Rescue the primary window if its autosaved frame restores off-screen or
    /// larger than the current screen — e.g. a frame a tiling window manager
    /// squeezed to the minimum, or one anchored to a now-disconnected display.
    /// One-shot: the clamp runs only for the first explicit primary content
    /// window at launch so it never fights a frame the user deliberately
    /// resizes later.
    ///
    /// Selector-based (not block-based) on purpose: `AppDelegate` is `@MainActor`,
    /// so the `@objc` handler receives the notification synchronously on the main
    /// thread with no `MainActor.assumeIsolated` assertion, and can read the
    /// just-keyed window straight off `notification.object` instead of guessing
    /// via `NSApp.keyWindow`.
    private func installInitialWindowFrameClamp() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(initialKeyWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc
    private func initialKeyWindowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        clampInitialWindowFrameIfNeeded(window)
    }

    private func endInitialWindowFrameClamp() {
        didClampInitialWindowFrame = true
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didBecomeKeyNotification, object: nil
        )
    }

    private func clampInitialWindowFrameIfNeeded(_ window: NSWindow) {
        guard !didClampInitialWindowFrame else { return }
        // The primary content window only. Don't consume the one-shot: keep
        // waiting for the real window to key.
        guard window.isAwesoMuxPrimaryContentWindow else { return }

        // Install the frame saver unconditionally, BEFORE the special-state
        // early return. If the primary window first keys in fullscreen/zoomed/
        // miniaturized (e.g. macOS restores a fullscreen Space), an install
        // gated behind that return would never fire — `didInstallPrimaryWindow
        // FrameSaver` would stay false for the whole process and the window
        // would silently forget its size once the user left that state.
        // `persistPrimaryWindowFrame` already skips special-state frames, so
        // installing here is safe.
        installPrimaryWindowFrameSaver()

        // A restored full-screen / zoomed window is a deliberate state that
        // `setFrame` would break, so leave it and consider the rescue done. The
        // miniaturized check is defensive: a miniaturized window typically does
        // not key until it is un-minimized (at which point `isMiniaturized` is
        // already false and the normal clamp runs), so this branch mainly guards
        // the full-screen / zoomed cases that do key while in their special state.
        if window.styleMask.contains(.fullScreen) || window.isZoomed || window.isMiniaturized {
            endInitialWindowFrameClamp()
            return
        }

        // A non-finite restored frame (corrupted/hand-edited autosave) can't be
        // reasoned about geometrically, and NaN would defeat the `!=` guard
        // below and reach `setFrame` — leave it to AppKit's own constrain pass.
        // No screen yet (all displays asleep, mid-reconfiguration) is transient.
        // Neither consumes the one-shot, so a later key transition can still
        // rescue once the state resolves.
        guard WindowFrameClampPolicy.isFinite(window.frame) else {
            logger.warning("skippedInitialWindowFrameClamp reason=nonFiniteFrame")
            return
        }
        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else {
            logger.warning("skippedInitialWindowFrameClamp reason=noScreen")
            return
        }

        endInitialWindowFrameClamp()
        let clamped = WindowFrameClampPolicy.clamp(
            window.frame,
            into: visibleFrame,
            minSize: CGSize(
                width: ContentView.minimumWindowWidth,
                height: ContentView.minimumWindowHeight
            )
        )
        guard clamped != window.frame else { return }
        logger.info("clampedInitialWindowFrame reason=offscreenOrOversizedRestore")
        window.setFrame(clamped, display: true)
    }

    /// Persist the primary window's frame under our stable key on every
    /// resize/move so the next launch restores it (INT-548). One-shot install;
    /// the observers live for the process. `didResize` (not just
    /// `didEndLiveResize`) is intentional — it also captures programmatic resizes
    /// from a tiling WM or a display reconfiguration, which is exactly the state
    /// we want remembered.
    private func installPrimaryWindowFrameSaver() {
        guard !didInstallPrimaryWindowFrameSaver else { return }
        didInstallPrimaryWindowFrameSaver = true
        let center = NotificationCenter.default
        // object: nil (NOT the specific window) — SwiftUI can recreate the
        // content NSWindow for a `Window` scene after launch, which would orphan
        // a window-scoped observer; we filter to the primary content window
        // inside the handler.
        for name in [
            NSWindow.didResizeNotification,
            NSWindow.didMoveNotification,
            NSWindow.didEndLiveResizeNotification
        ] {
            center.addObserver(
                self,
                selector: #selector(savePrimaryWindowFrame(_:)),
                name: name,
                object: nil
            )
        }
        // Closing the primary window does NOT quit the app (no
        // applicationShouldTerminateAfterLastWindowClosed; reopen via Dock). A
        // resize within the debounce window followed by a close would otherwise
        // leave the pending save to fire with no window left and drop the last
        // frame. Flush synchronously from the closing window before it releases.
        center.addObserver(
            self,
            selector: #selector(primaryWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    @objc
    private func primaryWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.isAwesoMuxPrimaryContentWindow else {
            return
        }
        pendingPrimaryWindowFrameSave?.cancel()
        pendingPrimaryWindowFrameSave = nil
        guard !window.styleMask.contains(.fullScreen),
              !window.isZoomed,
              !window.isMiniaturized else {
            return
        }
        // Save the closing window's frame directly — `persistPrimaryWindowFrame`
        // falls back to `NSApp.keyWindow`/`mainWindow`, which are already nil by
        // the time the debounced work would have fired.
        PrimaryWindowFramePersistence.save(window.frame)
    }

    @objc
    private func savePrimaryWindowFrame(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard window.isAwesoMuxPrimaryContentWindow else { return }
        // `didResize`/`didMove` fire continuously through a live drag (and a
        // tiling WM's nudges), so coalesce: persist only the settled frame once
        // the stream goes quiet. Avoids a per-frame UserDefaults write storm and
        // never persists a transitional mid-drag frame.
        primaryWindowForFrameSave = window
        pendingPrimaryWindowFrameSave?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                self.pendingPrimaryWindowFrameSave = nil
                self.persistPrimaryWindowFrame()
            }
        }
        pendingPrimaryWindowFrameSave = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.frameSaveDebounceInterval, execute: work
        )
    }

    /// Persist the current primary window's frame immediately (the debounced
    /// saver and the terminate flush both call this). Re-checks transient state
    /// at call time so a frame settled into fullscreen/zoom/mini isn't persisted.
    private func persistPrimaryWindowFrame() {
        guard let window = windowForPrimaryFramePersistence(),
            !window.styleMask.contains(.fullScreen),
            !window.isZoomed,
            !window.isMiniaturized else {
            return
        }
        PrimaryWindowFramePersistence.save(window.frame)
    }

    private func windowForPrimaryFramePersistence() -> NSWindow? {
        [
            primaryWindowForFrameSave,
            NSApp.keyWindow,
            NSApp.mainWindow
        ]
        .compactMap(\.self)
        .first { $0.isAwesoMuxPrimaryContentWindow }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let triggerDescription = currentEventDescription
        lastTerminateTrigger = triggerDescription
        let isSystemInitiated = isSystemInitiatedQuit

        // The synchronous risk walk (surface enumeration + libproc sampling)
        // now runs on the system-quit path too — this used to return
        // .terminateNow before touching libghostty to protect loginwindow's
        // shutdown timer. Accepted tradeoff: sampling is inherent to warning
        // about risky sessions at all, and the walk is bounded by the open
        // surface count. The timeout below caps everything after it.
        if let sessionStore {
            ghosttyRuntime?.refreshTerminalQuitConfirmationRisks(in: sessionStore)
        }
        if let ghosttyRuntime {
            floatingPanelController?.refreshTerminalQuitConfirmationRisks(using: ghosttyRuntime)
            popUpTerminalController?.refreshTerminalQuitConfirmationRisks(using: ghosttyRuntime)
        }
        let riskySessions = (sessionStore?.sessionsAtRiskOnQuit ?? [])
            + (floatingPanelController?.sessionsAtRiskOnQuit ?? [])
            + (popUpTerminalController?.sessionsAtRiskOnQuit ?? [])
        logger.info(
            "applicationShouldTerminate event=\(triggerDescription, privacy: .public) systemInitiated=\(isSystemInitiated, privacy: .public) riskySessions=\(riskySessions.count, privacy: .public)"
        )

        switch QuitTerminationPolicy.decision(
            isSystemInitiatedQuit: isSystemInitiated,
            hasRiskySessions: !riskySessions.isEmpty
        ) {
        case .terminateNow:
            return .terminateNow
        case .presentSystemQuitRiskWarning:
            guard !isSystemQuitWarningPresented else {
                logger.info(
                    "applicationShouldTerminate suppressedDuplicateSystemQuitWarning event=\(triggerDescription, privacy: .public)"
                )
                // .terminateCancel, not .terminateLater: the warning's resolve
                // closure replies exactly once for the FIRST deferral. A second
                // .terminateLater would never get its reply and hang the logout.
                return .terminateCancel
            }

            isSystemQuitWarningPresented = true
            presentSystemQuitRiskWarning(
                riskySessions: riskySessions,
                triggerDescription: triggerDescription
            )
            return .terminateLater
        case .presentUserQuitRiskAlert:
            guard !isQuitRiskAlertPresented else {
                logger.info(
                    "applicationShouldTerminate suppressedDuplicateQuitRiskAlert event=\(triggerDescription, privacy: .public)"
                )
                return .terminateCancel
            }

            isQuitRiskAlertPresented = true
            presentQuitRiskAlert(riskySessions: riskySessions)
            return .terminateLater
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowOrderDiagnostics.stop()
        let riskySessionCount = (sessionStore?.sessionsAtRiskOnQuitCount ?? 0)
            + (floatingPanelController?.sessionsAtRiskOnQuit.count ?? 0)
            + (popUpTerminalController?.sessionsAtRiskOnQuit.count ?? 0)
        logger.info(
            "applicationWillTerminate event=\(self.lastTerminateTrigger, privacy: .public) riskySessions=\(riskySessionCount, privacy: .public)"
        )

        // Drain the persistence debouncer; otherwise a Cmd-Q within the
        // 500 ms window drops the latest snapshot.
        if let sessionStore {
            SessionPersistence.flush(sessionStore)
        }
        // Flush the coalesced window-frame save so a Cmd-Q within the debounce
        // window still persists the final frame.
        pendingPrimaryWindowFrameSave?.cancel()
        pendingPrimaryWindowFrameSave = nil
        pendingSystemQuitWarningTimeout?.cancel()
        pendingSystemQuitWarningTimeout = nil
        persistPrimaryWindowFrame()
        for observer in focusObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        focusObservers.removeAll()
        // Idempotent: removes the initial-frame observer if it never fired (app
        // quit before any main-eligible window keyed). Scoped by name, so it
        // can't touch the block-based focus observers above.
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didBecomeKeyNotification, object: nil
        )
        // Symmetric with the clamp observer above: remove the frame-saver
        // observers too. Harmless on process exit, but keeps the cleanup
        // convention consistent.
        for name in [
            NSWindow.didResizeNotification,
            NSWindow.didMoveNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.willCloseNotification
        ] {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
        }
        remoteConnectivityObserver?.stop()
        remoteConnectivityObserver = nil
        popUpTerminalController?.tearDown()
        ghosttyRuntime?.bridgeGenerationRegistry?.drainForTermination()
    }

    /// Bind the session store and Ghostty runtime, then install focus
    /// observers. Idempotent across repeat invocations from SwiftUI's
    /// `.onAppear` (not guaranteed one-shot for `Window` content):
    /// only the first bind seeds the tracker baselines; later calls just
    /// refresh the references and re-evaluate against current focus.
    ///
    /// These references are expected to be `@State`-stable for the app's
    /// lifetime — the re-assignment on every `.onAppear` is a no-op in
    /// practice. If a future refactor makes them non-stable, the focus
    /// tracker baselines (seeded once via `didBindOnce`) will diverge from
    /// the new instance.
    func bind(
        sessionStore: SessionStore,
        ghosttyRuntime: GhosttyRuntime,
        floatingPanelController: TerminalPanelController,
        popUpTerminalController: TerminalPanelController,
        appSettingsStore: AppSettingsStore,
        terminalAppearancePreferencesCache: TerminalAppearancePreferencesCache,
        openSettings: @escaping () -> Void,
        openPrimaryWindow: @escaping () -> Void
    ) {
        self.sessionStore = sessionStore
        self.ghosttyRuntime = ghosttyRuntime
        self.floatingPanelController = floatingPanelController
        self.popUpTerminalController = popUpTerminalController
        self.appSettingsStore = appSettingsStore
        self.openSettings = openSettings
        self.openPrimaryWindow = openPrimaryWindow
        ghosttyRuntime.configureOutputMarksAttentionProvider {
            appSettingsStore.workspaces.value.outputMarksNeedsAttention
        }
        ghosttyRuntime.configureClipboardWritePolicyProvider {
            appSettingsStore.terminal.value.clipboardWritePolicy
        }
        ghosttyRuntime.configureConfirmClipboardReadProvider {
            appSettingsStore.terminal.value.confirmClipboardRead
        }
        ghosttyRuntime.configureCopyOnSelectProvider {
            appSettingsStore.terminal.value.copyOnSelect
        }
        ghosttyRuntime.configureCommandBridgeEnabledProvider {
            appSettingsStore.terminal.value.commandBridgeEnabled
        }
        ghosttyRuntime.configureAgentIntegrationsProvider {
            appSettingsStore.agentIntegrations.value
        }
        ghosttyRuntime.configureOpenDocumentHandler { [weak sessionStore] url in
            // Weak capture: the handler must not keep the store alive past its
            // natural lifetime. If the store is gone, silently drop the open.
            sessionStore?.openDocumentPane(fileURL: url)
        }
        // Live read (not a stored flag): the popover is .transient and closes on
        // any outside click without notifying our code, so only isShown at open
        // time is trustworthy (INT-748).
        DocumentComposeGuard.isComposing = {
            DocumentPaneView.activeCommentPopover?.isShown == true
        }
        notificationBridge.configurePreferencesProvider {
            NotificationPreferences(config: appSettingsStore.notifications.value)
        }
        if !didBindOnce {
            ghosttyRuntime.applyTerminalSettings()
            notificationTracker.reset(groups: sessionStore.groups)
            dockBounceTracker.reset(groups: sessionStore.groups)
            workspaceAnnouncementTracker.reset(groups: sessionStore.groups)
            remoteConnectivityObserver = RemoteConnectivityObserver {
                sessionStore.markRemotePanesPossiblyStale()
            }
            remoteConnectivityObserver?.start()
            installFocusObservers()
            didBindOnce = true
        }
        // Flush anything an observer dropped during the pre-bind window
        // (the gap between applicationDidFinishLaunching and the first
        // .onAppear), AND give a re-bind a chance to surface a newly-arrived
        // attention episode against the latest focus state.
        evaluateAndPostNotifications()

        // Cold-launch deep link: a notification click can deliver didReceive
        // before the store is bound (delegate registers in
        // applicationDidFinishLaunching; bind runs on root-view .onAppear),
        // which would otherwise silently drop the click. Same pre-bind
        // defense as evaluateAndPostNotifications above.
        if let pendingDeepLinkSessionID {
            self.pendingDeepLinkSessionID = nil
            selectDeepLinkedSession(pendingDeepLinkSessionID, in: sessionStore)
        }
    }

    /// Single funnel for notification deep links (immediate `didReceive` and
    /// the cold-launch replay in `bind`). The workspace can be closed between
    /// notification post and click — assigning a dangling ID would strand the
    /// app on "no workspace" with commands gated off, so drop it instead.
    private func selectDeepLinkedSession(
        _ sessionID: TerminalSession.ID,
        in sessionStore: SessionStore
    ) {
        guard sessionStore.session(id: sessionID) != nil else {
            logger.info("dropping notification deep link to closed workspace \(sessionID, privacy: .public)")
            return
        }
        sessionStore.selectedSessionID = sessionID
        surfacePrimaryWindow()
    }

    private var currentEventDescription: String {
        guard let event = NSApp.currentEvent else {
            return "nil"
        }

        return "type=\(event.type.rawValue) modifiers=\(event.modifierFlags.rawValue)"
    }

    private enum SystemQuitWarningOutcome: String {
        case timedOut
        case userCancelled
        case userConfirmed
    }

    private func presentSystemQuitRiskWarning(
        riskySessions: [TerminalSession],
        triggerDescription: String
    ) {
        pendingSystemQuitWarningTimeout?.cancel()
        pendingSystemQuitWarningTimeout = nil

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Quit awesoMux?",
            comment: "Title of the system quit warning dialog shown when sessions have running activity."
        )
        alert.informativeText = [
            quitRiskInformativeText(for: riskySessions),
            String(
                localized: "macOS will quit awesoMux automatically in a few seconds unless you cancel.",
                comment: "System quit warning body explaining the alert times out and defaults to quitting."
            )
        ].joined(separator: "\n\n")

        // Cancel added first → NSAlert auto-makes it the Return-key default,
        // matching every other destructive alert in this file (accidental
        // Return must not destroy work). The timeout below — not the
        // keyboard default — is what makes this dialog resolve to quit if
        // the user doesn't respond in time.
        alert.addButton(withTitle: String(
            localized: "Cancel",
            comment: "Default button on the system quit warning dialog. Cancels the system-initiated quit."
        ))
        let quitButton = alert.addButton(withTitle: String(
            localized: "Quit Anyway",
            comment: "Destructive button on the system quit warning dialog. Quits the app despite running activity."
        ))
        quitButton.hasDestructiveAction = true

        var didResolve = false
        // Strong self on purpose: this closure owes NSApp a
        // reply(toApplicationShouldTerminate:) — a weak self that early-returns
        // would swallow it and hang the logout. No cycle: the closure lives
        // only in the timeout work item and the alert completion, both of
        // which are done once it fires. `alert` stays weak because the sheet
        // completion handler is retained by the alert itself.
        let resolve: (SystemQuitWarningOutcome) -> Void = { [self, weak alert] outcome in
            guard !didResolve else { return }
            didResolve = true
            pendingSystemQuitWarningTimeout?.cancel()
            pendingSystemQuitWarningTimeout = nil
            isSystemQuitWarningPresented = false
            logger.info(
                "applicationShouldTerminate systemQuitWarningResolved event=\(triggerDescription, privacy: .public) outcome=\(outcome.rawValue, privacy: .public) riskySessions=\(riskySessions.count, privacy: .public)"
            )
            // Only the timeout path still has the alert on screen; a button
            // click already dismissed it before its completion ran. End the
            // presentation the documented way for each mode: endSheet for
            // beginSheetModal, abortModal for runModal (the pending
            // reply/completion then no-ops via didResolve).
            if let alert {
                if let sheetParent = alert.window.sheetParent {
                    sheetParent.endSheet(alert.window)
                } else if alert.window.isVisible {
                    NSApp.abortModal()
                    alert.window.orderOut(nil)
                }
            }
            NSApp.reply(toApplicationShouldTerminate: outcome != .userCancelled)
        }

        let timeout = DispatchWorkItem {
            MainActor.assumeIsolated {
                resolve(.timedOut)
            }
        }
        pendingSystemQuitWarningTimeout = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.systemQuitWarningTimeout,
            execute: timeout
        )

        let reply: (NSApplication.ModalResponse) -> Void = { response in
            // Cancel = first button, Quit Anyway = second button (matches
            // presentQuitRiskAlert's convention).
            resolve(response == .alertSecondButtonReturn ? .userConfirmed : .userCancelled)
        }

        // Pattern adapted from ghostty-org/ghostty
        // macos/Sources/App/macOS/AppDelegate.swift (MIT): system shutdown gets
        // a short warning plus NSApp.reply(toApplicationShouldTerminate:), with
        // timeout defaulting to quit so loginwindow is not held indefinitely.
        switch quitAlertPresentationTarget() {
        case .sheet(let window):
            alert.beginSheetModal(for: window, completionHandler: reply)
        case .appModal:
            reply(alert.runModal())
        }
    }

    private func presentQuitRiskAlert(riskySessions: [TerminalSession]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Quit awesoMux?",
            comment: "Title of the quit confirmation dialog shown when sessions have running activity."
        )
        alert.informativeText = quitRiskInformativeText(for: riskySessions)

        // Cancel is intentionally first so it's the default (Return-key)
        // button — accidental Return on this dialog must NOT destroy work.
        // The destructive button is marked so VoiceOver announces it as
        // such and macOS renders it accordingly.
        alert.addButton(withTitle: String(
            localized: "Cancel",
            comment: "Default button on the quit confirmation dialog. Cancels the quit."
        ))
        let quitButton = alert.addButton(withTitle: String(
            localized: "Quit Anyway",
            comment: "Destructive button on the quit confirmation dialog. Quits the app despite running activity."
        ))
        quitButton.hasDestructiveAction = true
        alert.informativeText += "\n\n" + String(
            localized: "Press ⌘Return to quit anyway. Esc cancels.",
            comment: "Keyboard hint line on the quit confirmation dialog."
        )

        let reply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.isQuitRiskAlertPresented = false
            // Cancel = first button, Quit Anyway = second button.
            NSApp.reply(toApplicationShouldTerminate: response == .alertSecondButtonReturn)
        }

        switch quitAlertPresentationTarget() {
        case .sheet(let window):
            alert.beginSheetModal(
                for: window,
                keyboardAccept: quitButton,
                completionHandler: reply
            )
        case .appModal:
            // No suitable window: present app-modal. We're already on
            // @MainActor inside applicationShouldTerminate, so call runModal
            // directly — no Task hop, no reply race.
            reply(alert.runModal(keyboardAccept: quitButton))
        }
    }

    private enum QuitAlertPresentationTarget {
        case sheet(NSWindow)
        case appModal
    }

    private func quitAlertPresentationTarget() -> QuitAlertPresentationTarget {
        let orderedWindows = NSApp.orderedWindows
        let focusedWindows = [NSApp.mainWindow, NSApp.keyWindow].compactMap { $0 }

        func candidate(
            for window: NSWindow?
        ) -> QuitAlertPresentationPolicy.WindowCandidate<ObjectIdentifier>? {
            guard let window else { return nil }
            return QuitAlertPresentationPolicy.WindowCandidate(
                id: ObjectIdentifier(window),
                isVisible: window.isVisible,
                canBecomeMain: window.canBecomeMain,
                hasAttachedSheet: window.attachedSheet != nil,
                isAttachedSheet: window.sheetParent != nil
            )
        }

        let target = QuitAlertPresentationPolicy.target(
            mainWindow: candidate(for: NSApp.mainWindow),
            keyWindow: candidate(for: NSApp.keyWindow),
            orderedWindows: orderedWindows.compactMap { candidate(for: $0) }
        )

        switch target {
        case .sheet(let id):
            guard let window = (focusedWindows + orderedWindows).first(where: {
                ObjectIdentifier($0) == id
            }) else {
                return .appModal
            }
            return .sheet(window)
        case .appModal:
            return .appModal
        }
    }

    private func quitRiskInformativeText(for sessions: [TerminalSession]) -> String {
        let titlePreview = sessions.prefix(3)
            .map { "“\(AwesoMuxApp.sanitizedAlertTitle($0.title))”" }
            .joined(separator: ", ")
        let extra = sessions.count > 3
            ? LocalizedPluralStrings.quitOverflowSuffix(count: sessions.count - 3)
            : ""
        // Tailor the noun to the actual cause. After INT-216, "agent activity"
        // would lie to a user who is only running shell processes (vim, ssh,
        // npm) — VoiceOver users in particular have no other channel to
        // disambiguate why the prompt fired.
        let activityNoun: String
        let hasAgent = sessions.contains { $0.panes.contains { $0.agentKind != .shell } }
        let hasShell = sessions.contains {
            $0.panes.contains { $0.agentKind == .shell && $0.isQuitRisk() }
        }
        switch (hasAgent, hasShell) {
        case (true, true):
            activityNoun = String(
                localized: "running work",
                comment: "Activity noun in the quit dialog body when both agents and shell processes are at risk."
            )
        case (true, false):
            activityNoun = String(
                localized: "agent activity",
                comment: "Activity noun in the quit dialog body when only agents are at risk."
            )
        case (false, true), (false, false):
            // (false, true) is the shell-only case. (false, false) is
            // unreachable from the quit gate — any at-risk session has a risky
            // agent or shell pane — but fall back to the shell noun defensively.
            activityNoun = String(
                localized: "a running shell process",
                comment: "Activity noun in the quit dialog body when only shell processes are at risk."
            )
        }

        return LocalizedPluralStrings.quitSessionsAtRisk(
            titlePreview: titlePreview,
            activityNoun: activityNoun,
            count: sessions.count,
            overflowSuffix: extra
        )
    }

    func requestNotificationAuthorizationIfNeeded() {
        notificationBridge.requestAuthorizationWithExplanationIfNeeded()
    }

    /// Re-evaluate the attention policy against the current store + focus
    /// state and post any newly-eligible interruptive notifications.
    /// Invoked on session-group changes, app-focus changes, and bind.
    ///
    /// `isAppActiveOverride` lets focus-edge observers pin the focus state
    /// at observation time. Without it, a `Task { @MainActor }` hop reads
    /// `NSApp.isActive` at task-execution time — and a quick resign/become
    /// flap inside the hop would have us evaluating a `didResignActive`
    /// event as if the app were still active, suppressing the deferred
    /// banner this PR exists to surface.
    func evaluateAndPostNotifications(isAppActiveOverride: Bool? = nil) {
        guard let sessionStore else {
            return
        }

        let isAppActive = isAppActiveOverride ?? NSApp.isActive
        let outputMarksNeedsAttention = appSettingsStore?
            .config
            .workspaces
            .outputMarksNeedsAttention ?? true
        let notificationConfig = appSettingsStore?.notifications.value ?? .defaultValue
        let notificationPreferences = NotificationPreferences(config: notificationConfig)
        let events = notificationTracker.notificationEvents(
            afterUpdating: sessionStore.groups,
            selectedSessionID: sessionStore.selectedSessionID,
            isAppActive: isAppActive,
            outputMarksNeedsAttention: outputMarksNeedsAttention,
            notifyOnNeedsAttention: notificationConfig.notifyOnNeedsAttention,
            notifyOnTurnDone: notificationConfig.notifyOnTurnDone,
            turnDoneAlertsWhenFocused: notificationConfig.turnDoneAlertsWhenFocused
        )
        let shouldBounceDock = dockBounceTracker.shouldRequestDockBounce(
            afterUpdating: sessionStore.groups,
            isAppActive: isAppActive,
            outputMarksNeedsAttention: outputMarksNeedsAttention,
            allowsDockBounce: notificationPreferences.shouldBounceDockForNeedsAttention()
        )

        for event in events {
            notificationBridge.postWorkspaceNotification(event)
        }
        if shouldBounceDock {
            requestDockAttentionBounce()
        }

        // WCAG 4.1.3: speak the rollup transition a VoiceOver user can't see on
        // the sidebar badge. Tracked separately from the banner because it also
        // covers `.done`/`.error` (which don't bump unread) and stays specific to
        // the workspace + loudest agent. Debounced so a burst doesn't machine-gun.
        let announcements = workspaceAnnouncementTracker.announcements(
            afterUpdating: sessionStore.groups,
            selectedSessionID: sessionStore.selectedSessionID,
            isAppActive: isAppActive
        )
        scheduleWorkspaceAttentionAnnouncement(announcements)
    }

    private func scheduleWorkspaceAttentionAnnouncement(
        _ announcements: [WorkspaceAttentionAnnouncementTracker.Announcement]
    ) {
        guard !announcements.isEmpty else {
            return
        }
        pendingWorkspaceAnnouncements.append(contentsOf: announcements)
        // Non-resetting batch drain (INT-504 R2 item 1): a single drain task
        // owns one fair 500ms window. Later announcements ride the in-flight
        // window instead of cancelling-and-restarting it — a resetting timer let
        // a steady trickle of crossings starve an earlier valid announcement
        // past its own window, where the live recheck then dropped it.
        guard pendingWorkspaceAnnouncementTask == nil else {
            return
        }
        pendingWorkspaceAnnouncementTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else {
                return
            }
            self.pendingWorkspaceAnnouncementTask = nil
            let batch = self.pendingWorkspaceAnnouncements
            self.pendingWorkspaceAnnouncements = []
            self.drainWorkspaceAttentionAnnouncements(batch)
        }
    }

    /// Rebuilds each queued crossing from the LIVE rollup at drain time, then
    /// speaks the collapsed result. Rebuilding (not re-validating the captured
    /// snapshot) fixes the stale-identity bug (INT-504 R2 item 2): a workspace's
    /// title / winning pane / winning agent kind may have changed while its
    /// rollup stayed announce-worthy, and VoiceOver must speak the current
    /// identity. A workspace that left the announce-worthy set returns nil and is
    /// dropped.
    private func drainWorkspaceAttentionAnnouncements(
        _ batch: [WorkspaceAttentionAnnouncementTracker.Announcement]
    ) {
        let live = WorkspaceAttentionAnnouncementTracker.reconcile(batch) { [weak self] sessionID in
            guard let session = self?.sessionStore?.session(id: sessionID) else {
                return nil
            }
            let rollup = session.agentRollup()
            guard WorkspaceAttentionAnnouncementTracker.isAnnounceWorthy(rollup.state),
                  !WorkspaceAttentionAnnouncementTracker.isDuplicateOfSpecificAnnouncement(rollup) else {
                return nil
            }
            return WorkspaceAttentionAnnouncementTracker.Announcement(
                sessionID: sessionID,
                title: session.title,
                agentKind: rollup.winningAgentKind,
                state: rollup.state
            )
        }
        WorkspaceAttentionAnnouncementDelivery.deliver(live)
    }

    // Bug 2 fix: focus changes need to re-fire the policy evaluation.
    // Otherwise an attention transition that landed while the user was
    // looking at awesoMux (visible-state-only) never gets the interruptive
    // banner upgrade when they later look away.
    //
    // The active-space (Mission Control) observer was tried and dropped.
    // `NSApp.isActive` does not change on a Spaces switch alone, so the
    // observer fired but the policy couldn't see the difference. Worse, it
    // interrupted macOS's own VoiceOver Space-name announcement on every
    // swipe. The `didResign/didBecomeActive` pair already covers the cases
    // where awesoMux's effective foreground status actually changes.
    private func installFocusObservers() {
        let appCenter = NotificationCenter.default

        let resigned = appCenter.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateAndPostNotifications(isAppActiveOverride: false)
                // Quiet-moment surface GC: the user just task-switched away.
                // Sweep any libghostty surfaces orphaned by a previous
                // session/pane removal that didn't route through
                // `discardSurfaces(for:)`. Non-destructive — only touches
                // surfaces whose pane IDs aren't referenced by any main or
                // floating session.
                self?.reconcileGhosttySurfaces()
            }
        }

        let became = appCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateAndPostNotifications(isAppActiveOverride: true)
            }
        }

        focusObservers = [resigned, became]
    }

    /// Sweep libghostty surfaces that aren't referenced by any main or
    /// floating session. Belt-and-suspenders against pane-removal paths
    /// that don't route through `runtime.discardSurfaces(for:)` — runs at
    /// quiet moments (app resign-active) so the work doesn't fight a hot
    /// interaction. Safe to call any time: the retain set unions main and
    /// floating stores, so live surfaces are always covered.
    private func reconcileGhosttySurfaces() {
        guard let ghosttyRuntime, let sessionStore else {
            return
        }
        let retainedPaneIDs = SurfaceRetainSet.paneIDs(
            mainGroups: sessionStore.groups,
            auxiliaryPaneIDs: (floatingPanelController?.retainedPaneIDs ?? [])
                .union(popUpTerminalController?.retainedPaneIDs ?? [])
        )
        ghosttyRuntime.discardSurfacesNotIn(retainedPaneIDs)
    }

    private func requestDockAttentionBounce() {
        guard !NSApp.isActive else {
            return
        }
        _ = NSApp.requestUserAttention(.informationalRequest)
    }

    func updateDockBadge(total: Int) {
        NSApp.dockTile.badgeLabel = total > 0 ? "\(total)" : nil

        if total == 0 {
            pendingDockBadgeAnnouncement?.cancel()
            pendingDockBadgeAnnouncement = nil
        } else if total > lastDockBadgeTotal {
            scheduleDockBadgeAnnouncement()
        }

        lastDockBadgeTotal = total
    }

    // Frontmost-app mirror of the dock badge transition for VoiceOver users.
    // Cross-app delivery is handled by `WorkspaceNotificationBridge` via
    // `UNUserNotificationCenter` (`.timeSensitive`); a posted accessibility
    // announcement on a backgrounded `NSApplication.shared` is not reliably
    // spoken. The `@MainActor` isolation makes the cancel-then-reassign atomic.
    private func scheduleDockBadgeAnnouncement() {
        pendingDockBadgeAnnouncement?.cancel()
        pendingDockBadgeAnnouncement = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else {
                return
            }

            let total = lastDockBadgeTotal
            guard total > 0 else {
                return
            }

            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: dockBadgeAnnouncement(total: total),
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue
                ]
            )
        }
    }

    private func dockBadgeAnnouncement(total: Int) -> String {
        LocalizedPluralStrings.dockBadgeSessionsNeedAttention(total: total)
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    // nonisolated — do not access AppDelegate's @MainActor state directly
    // from this method without checking. UNUserNotificationCenterDelegate
    // methods are documented to be delivered on the main thread, so
    // `MainActor.assumeIsolated` is the right idiom: cheap, synchronous,
    // crashes loudly if Apple's contract ever changes.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Foreground awesoMux already shows the visibleState channels
        // (sidebar dot, tab indicator, dock badge + AX announcement).
        // Adding a banner + sound on top is overkill in foreground and
        // also makes a VoiceOver user hear the banner read AND the dock
        // badge announcement back-to-back. Reserve the banner for the
        // away case; let the foreground path stay quiet save for the
        // already-firing visibleState channels.
        let isActive = MainActor.assumeIsolated { NSApp.isActive }
        let isTurnDone = notification.request.content.userInfo[
            WorkspaceNotificationUserInfoKey.kind
        ] as? String == WorkspaceNotificationUserInfoKey.turnDoneKindValue
        let options = MainActor.assumeIsolated {
            notificationBridge.foregroundPresentationOptions(
                isAppActive: isActive,
                isTurnDone: isTurnDone
            )
        }
        completionHandler(options)
    }

    /// Clicking (or acting on) a workspace-needs-attention banner brings the
    /// app forward and selects the workspace it was posted for. Group
    /// expansion, if the workspace's group is collapsed, is handled by
    /// `SidebarView`'s own `onChange(of: selectedSessionID)` — that also
    /// covers every other way selection can land in a collapsed group
    /// (⌘+number, prev/next workspace), so it isn't duplicated here.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        MainActor.assumeIsolated {
            guard let sessionID = WorkspaceNotificationRouting.sessionID(fromUserInfo: userInfo) else {
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            if let sessionStore {
                selectDeepLinkedSession(sessionID, in: sessionStore)
            } else {
                // Cold launch: store not bound yet — bind(...) replays this.
                pendingDeepLinkSessionID = sessionID
            }
        }
        completionHandler()
    }
}

private extension SessionStore {
    var hasWorkspaceNeedingInputForMenuBar: Bool {
        groups.contains { group in
            group.sessions.contains { $0.needsAcknowledgement }
        }
    }
}
