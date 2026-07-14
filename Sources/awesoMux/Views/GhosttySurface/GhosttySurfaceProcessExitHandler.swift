import AppKit
import AwesoMuxCore

extension GhosttySurfaceNSView {
    func closeAfterProcessExit(processAlive: Bool) {
        if ignoresProcessExitAfterCommandBridgeHeal {
            commandExitCache.clear()
            return
        }

        if commandBridgeEnactor.handleProcessExit(processAlive: processAlive) {
            return
        }

        // libghostty fires this callback for any surface close, including
        // runtime-side requests where the child process is still running.
        // A still-alive close is a destroy request, which we treat the same
        // as a user-initiated last-pane recycle (no announcement).
        guard !processAlive else {
            recycleOrClosePane()
            return
        }

        // Read the LIVE pane count from the store — the cached `session`
        // snapshot can be stale if a sibling pane just closed and SwiftUI
        // hasn't re-rendered this view yet. A stale "1 pane" reading would
        // leak the dead surface; a stale "many panes" reading would route
        // through the multi-pane signaling branch and skip workspace close.
        let liveLayout = sessionStore.session(id: sessionID)?.layout
        let liveCount = liveLayout?.paneCount ?? session.layout.paneCount
        guard liveCount > 1 else {
            let exitedWithError = commandExitCache.hasFreshNonZeroExitCode(
                now: Date().timeIntervalSinceReferenceDate
            )
            closeExitedPaneAndDiscardSurfaces()
            TerminalAccessibilityAnnouncer.announceWorkspaceClosedAfterProcessExit(
                exitedWithError: exitedWithError
            )
            return
        }

        // M2 (INT-504 review): record the error on the EXITING pane while it is
        // still in the layout, BEFORE `closePane` removes it. The prior ordering
        // closed first, so the dead pane was already gone and the badge no-oped —
        // a regression from the pre-PR session-level `.processError`. Recording
        // first lands the badge on the correct pane and never on the surviving
        // sibling. Capture focus before any teardown: once the surface is gone
        // this view detaches from its window and `terminalIsFocused` reads false,
        // defeating the "don't badge when focused" guard.
        let wasFocused = terminalIsFocused
        let now = Date().timeIntervalSinceReferenceDate
        let shouldSignal = commandExitCache.shouldSignalSiblingPaneExit(
            now: now,
            paneCount: liveCount
        )
        if shouldSignal {
            sessionStore.recordSiblingPaneExitError(
                in: sessionID,
                exitingPaneID: paneID,
                terminalIsFocused: wasFocused
            )
            let sessionTitle =
                sessionStore.session(id: sessionID)?.title
                ?? session.title
            TerminalAccessibilityAnnouncer.announceSiblingPaneExitError(
                sessionTitle: sessionTitle
            )
        }
        // Consume-and-clear the cache regardless of whether we signaled, so the
        // next close can't double-attribute this exit code to a sibling. The
        // contract documented above `clearStaleErrorState` expects the cache to
        // be reset whenever an exit-code consumer fires.
        commandExitCache.clear()

        // The cache was already consumed-and-cleared above, so the surface
        // teardown branches only need to discard the orphaned surfaces.
        switch sessionStore.closePane(id: paneID, in: sessionID, origin: .processExit) {
        case let .pane(closedPaneID):
            runtime.discardSurface(for: closedPaneID)

        case let .session(_, paneIDs):
            paneIDs.forEach { runtime.discardSurface(for: $0) }

        case nil:
            runtime.discardSurface(for: paneID)
        }
    }

    /// Forwarder retained for the existing view tests, which drive the bridge
    /// exclusively through the view surface. New call sites use the enactor.
    @MainActor
    func beginCommandBridgeStatusWatch(channel: AmxStatusChannel?) {
        commandBridgeEnactor.beginStatusWatch(channel: channel)
    }

    /// Forwarder retained for the existing view tests. See `beginCommandBridgeStatusWatch`.
    @MainActor
    func handleCommandBridgeStatusEvents(_ events: [AmxStatusEvent]) {
        commandBridgeEnactor.handleStatusEvents(events)
    }

    /// User-initiated reconnect from the disconnected overlay (INT-697),
    /// forwarded from `GhosttyRuntime.reconnectRemotePane(in:)`.
    @MainActor
    func reconnectRemotePane() {
        commandBridgeEnactor.beginManualReconnect()
    }

    /// The enactor remounts a healed pane back through this AppKit path: discard
    /// the old surface, build a fresh view, and mount it into the scroll
    /// container. Stays on the view — it touches `scrollContainer`, `contentSize`,
    /// and the layer.
    @MainActor
    func remountFreshSurfaceAfterCommandBridgeHeal(
        _ recovery: SessionStore.CommandBridgePaneHealResult
    ) {
        ignoresProcessExitAfterCommandBridgeHeal = true

        let container = scrollContainer
        let mountedContentSize = contentSize
        let enabledFileDropSources = enabledAgentRuntimeFileDropSources

        runtime.discardSurface(for: recovery.paneID)

        guard let container,
            let liveSession = sessionStore.session(id: recovery.sessionID)
        else {
            return
        }

        let freshView = runtime.surfaceView(
            sessionStore: sessionStore,
            session: liveSession,
            pane: recovery.pane,
            enabledAgentRuntimeFileDropSources: enabledFileDropSources,
            grokIconEnabled: grokIconEnabled
        )
        container.mount(
            freshView,
            isActive: liveSession.activePaneID == recovery.paneID,
            contentSize: mountedContentSize
        )
    }

    func closeExitedPaneAndDiscardSurfaces() {
        switch sessionStore.closePane(id: paneID, in: sessionID, origin: .processExit) {
        case let .session(_, paneIDs):
            paneIDs.forEach { runtime.discardSurface(for: $0) }
        case let .pane(closedPaneID):
            runtime.discardSurface(for: closedPaneID)
        case nil:
            runtime.discardSurface(for: paneID)
        }
        clearCachedExitCode()
    }

    func clearCachedExitCode() {
        commandExitCache.clear()
    }

    func recycleOrClosePane() {
        Self.recycleAndAnnounce(
            sessionID: sessionID,
            sessionStore: sessionStore,
            runtime: runtime
        )
    }

    @MainActor
    static func recycleAndAnnounce(
        sessionID: TerminalSession.ID,
        sessionStore: SessionStore,
        runtime: GhosttyRuntime
    ) {
        // Read the pre-recycle state so VoiceOver users get the same two-fold
        // signal sighted users do (red dot vanishes + fresh prompt) when
        // recycling out of `.error`. `recycleActivePane` flips state to
        // `.running` synchronously, so capture before the call.
        let priorState = sessionStore.session(id: sessionID)?.agentState
        guard let replacedPaneID = sessionStore.recycleActivePane(in: sessionID) else {
            return
        }
        runtime.discardSurface(for: replacedPaneID)
        if priorState == .error {
            TerminalAccessibilityAnnouncer.announceErrorClearedAndShellRecycled()
        } else {
            TerminalAccessibilityAnnouncer.announceShellRecycled()
        }
    }

}
