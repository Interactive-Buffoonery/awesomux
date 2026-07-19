import AppKit
import AwesoMuxCore
import GhosttyKit
import OSLog

private struct ForegroundProcessSample: Sendable {
    var hasLiveSurface: Bool
    var processExited: Bool = false
    var pid: pid_t?
    var comm: String?
    var foregroundHasChildren: Bool?
}

extension GhosttySurfaceNSView {
    /// Sample foreground-process liveness for the quit gate. Bridged panes are
    /// authoritatively safe (work survives quit); otherwise classify from
    /// libghostty's foreground pid + a libproc child check.
    @MainActor
    func foregroundProcessLiveness() -> ForegroundProcessLiveness {
        foregroundProcessLivenessAndSample().liveness
    }

    @MainActor
    private func foregroundProcessLivenessAndSample() -> (
        liveness: ForegroundProcessLiveness,
        sample: ForegroundProcessSample?
    ) {
        if commandBridgeSessionID != nil {
            guard
                let rawPID = commandBridgeEnactor.respawnLedger.lastIncarnation?.pid,
                let daemonPID = pid_t(exactly: rawPID)
            else {
                return (.bridged, nil)
            }
            return (
                ProcessLivenessProbe.bridgedLiveness(daemonPID: daemonPID),
                nil
            )
        }
        let sample = foregroundProcessSample()
        guard sample.hasLiveSurface else {
            return (.unsampled, sample)
        }
        guard !sample.processExited else {
            return (.exited, sample)
        }
        return (
            ForegroundProcessLiveness.classify(
                processExited: false,
                foregroundComm: sample.comm,
                foregroundHasChildren: sample.foregroundHasChildren
            ),
            sample
        )
    }

    /// Foreground evidence for the document-nudge prompt gate (INT-569).
    /// Bridged panes read the daemon's foreground process group via the
    /// command bridge; non-bridged local panes reuse the quit-gate sampler —
    /// libghostty tracks the surface's foreground pid directly, so the same
    /// p_comm evidence exists without a bridge session. Nil = no usable
    /// evidence; every consumer treats it as deny (fail closed).
    @MainActor
    func documentNudgeForegroundComm() -> String? {
        if commandBridgeSessionID != nil {
            return commandBridgeEnactor.foregroundComm()
        }
        let sample = foregroundProcessSample()
        guard sample.hasLiveSurface, !sample.processExited, let comm = sample.comm else {
            Self.nudgeGateLogger.info(
                "nudge probe: pane \(self.paneID.uuidString, privacy: .public) non-bridged sample denied (liveSurface=\(sample.hasLiveSurface, privacy: .public) exited=\(sample.processExited, privacy: .public) commResolved=\(sample.comm != nil, privacy: .public))"
            )
            return nil
        }
        return comm
    }

    /// INT-569 field diagnostics for the document-nudge evidence chain.
    private nonisolated static let nudgeGateLogger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "DocumentNudgeGate"
    )

    @MainActor
    private func foregroundProcessSample() -> ForegroundProcessSample {
        guard let surface else {
            return ForegroundProcessSample(hasLiveSurface: false)
        }
        if ghostty_surface_process_exited(surface) {
            return ForegroundProcessSample(hasLiveSurface: true, processExited: true)
        }
        guard let pid = pid_t(exactly: ghostty_surface_foreground_pid(surface)), pid > 0 else {
            return ForegroundProcessSample(hasLiveSurface: true)
        }
        let comm = ProcessLivenessProbe.foregroundComm(pid: pid)
        let hasChildren: Bool?
        if let comm, ShellRecognition.isRecognizedShell(comm) {
            hasChildren = ProcessLivenessProbe.hasChildren(pid: pid)
        } else {
            hasChildren = nil
        }
        return ForegroundProcessSample(
            hasLiveSurface: true,
            pid: pid,
            comm: comm,
            foregroundHasChildren: hasChildren
        )
    }

    /// Foreground-process incarnation for the document-nudge prompt gate's
    /// generation check (INT-569 follow-up). Mirrors
    /// `documentNudgeForegroundComm()`'s bridged/non-bridged branching so the
    /// same probe backs both the comm-name evidence and the pid/start-time
    /// evidence. Nil = no usable evidence; the gate fails closed on nil.
    ///
    /// The bridged branch deliberately does NOT use
    /// `commandBridgeEnactor.respawnLedger.lastIncarnation` (the DAEMON's own
    /// pid/createdAt) — a persistent bridged session's daemon survives the
    /// user quitting and restarting the agent CLI inside it, so the daemon
    /// incarnation staying fixed across a CLI relaunch would silently
    /// re-trust the fresh, unverified process. It walks to the actual
    /// foreground process INSIDE that daemon session instead, same as
    /// `documentNudgeForegroundComm()` does for its comm-name evidence.
    @MainActor
    func documentNudgeForegroundGeneration() -> AgentForegroundIncarnation? {
        if commandBridgeSessionID != nil {
            guard
                let rawDaemonPID = commandBridgeEnactor.respawnLedger.lastIncarnation?.pid,
                let daemonPID = pid_t(exactly: rawDaemonPID),
                let foregroundPID = ProcessLivenessProbe.terminalForegroundPID(daemonPID: daemonPID),
                let startedAt = ProcessLivenessProbe.processStartTime(pid: foregroundPID)
            else {
                return nil
            }
            return AgentForegroundIncarnation(pid: Int(foregroundPID), startedAt: startedAt)
        }
        let sample = foregroundProcessSample()
        guard sample.hasLiveSurface, !sample.processExited, let pid = sample.pid,
            let startedAt = ProcessLivenessProbe.processStartTime(pid: pid)
        else {
            return nil
        }
        return AgentForegroundIncarnation(pid: Int(pid), startedAt: startedAt)
    }

    /// Passive "agent exited, shell survived" detector (INT-552): when an
    /// agent-tagged pane's sampled foreground is an idle shell, the agent
    /// process is gone, so synthesize the same `.sessionEnd` reset a
    /// trustworthy quit hook would have delivered.
    ///
    /// Startup-race invariant: hook events execute from inside the
    /// already-running agent process, so by the time any event tags this pane
    /// with an agent kind the foreground pid has already transitioned off the
    /// shell — the sampler cannot observe a pre-exec idle-shell window and
    /// immediately undo a fresh kind.
    @MainActor
    func detectAgentExitedToShell() {
        // Live store read, not the view's captured pane snapshot: after a
        // reset the snapshot stays non-shell until the next SwiftUI update
        // pass, which would re-probe (and re-announce) every sampler tick.
        let foregroundProcess = foregroundProcessLivenessAndSample()
        sessionStore.clearManagedSSHObservationIfExitedToLocalShell(
            sessionID: sessionID,
            paneID: paneID,
            liveness: foregroundProcess.liveness
        )
        // Codex's SessionStart hook arrives batched with the first prompt, so a
        // fresh Codex pane shows the generic shell icon until the user types —
        // and its fragile text signature (splash banner / prompt-anchored
        // launch) may never match. The live foreground `comm` is authoritative:
        // tag the pane Codex the moment its process is in front, mirroring the
        // OpenCode/Grok fast-path. This also gives the liveness reset below a
        // correctly-tagged pane once the agent exits back to the shell.
        if let foregroundAgentKind = AgentProcessRecognition.agentKind(forCommand: foregroundProcess.sample?.comm) {
            applyDetectedAgentOutput(
                AgentOutputDetection(
                    state: .waiting,
                    agentKind: foregroundAgentKind,
                    agentKindIsAuthoritative: true
                ))
        }

        guard
            let agentKind = sessionStore.session(id: sessionID)?
                .layout.pane(id: paneID)?.agentKind,
            agentKind != .shell,
            AgentLivenessPolicy.shouldResetAgentChrome(
                agentKind: agentKind,
                liveness: foregroundProcess.liveness
            )
        else {
            return
        }
        // App-synthesized from process liveness, not parsed from the agent
        // side channel. `.unknown` source + nil kind passes the consent gate
        // by design — this resets our own state rather than accepting
        // provider input — and routing through the shared wrapper keeps
        // detector suppression and VoiceOver announcements consistent with
        // real hook-delivered session-end events.
        applyAgentRuntimeEvent(
            AgentRuntimeEvent(
                source: .unknown,
                executionState: .idle,
                phase: .sessionEnd
            ))
    }

    @MainActor
    func shellActivitySnapshot() -> ShellActivitySnapshot? {
        guard session.layout.pane(id: paneID)?.agentKind == .shell,
            let isAwayFromPrompt = promptMarkerIsAwayFromPrompt()
        else {
            return nil
        }

        if !isAwayFromPrompt {
            shellCommandFinishedIdleLatched = false
        }

        return ShellActivitySnapshot(
            sessionID: sessionID,
            paneID: paneID,
            isBusy: Self.resolvedShellActivityBusy(
                promptMarkerIsAwayFromPrompt: isAwayFromPrompt,
                commandFinishedIdleLatched: shellCommandFinishedIdleLatched
            )
        )
    }

    static func resolvedShellActivityBusy(
        promptMarkerIsAwayFromPrompt: Bool,
        commandFinishedIdleLatched: Bool
    ) -> Bool {
        commandFinishedIdleLatched ? false : promptMarkerIsAwayFromPrompt
    }

    @MainActor
    func promptMarkerIsAwayFromPrompt() -> Bool? {
        guard let surface else {
            return nil
        }

        let isAwayFromPrompt = ghostty_surface_needs_confirm_quit(surface)
        if !isAwayFromPrompt {
            terminalPromptObserved = true
        }
        return isAwayFromPrompt
    }

    // No `draw(_:)` override: libghostty owns presentation on its own renderer
    // thread (vsync-paced CVDisplayLink, `vendor/ghostty/src/renderer/generic.zig`),
    // exactly as Ghostty.app's `SurfaceView_AppKit` does. We used to ALSO call
    // `ghostty_surface_draw` synchronously from `draw(_:)`, which under a chatty
    // PTY fired at up to 120Hz/pane and forced a redundant main-thread present on
    // top of the renderer thread — starving the main thread and stalling scroll
    // (blank-until-catch-up, SGR-report leak). The passive shell/agent samplers
    // that used to piggyback on that `draw()` now run on `visibleStateSamplingTask`.

    func updateTerminalTitle(_ title: String) {
        sessionStore.updatePane(sessionID: sessionID, paneID: paneID, title: title)
    }

    func updateWorkingDirectory(_ workingDirectory: String) {
        sessionStore.updatePane(
            sessionID: sessionID,
            paneID: paneID,
            workingDirectory: workingDirectory
        )
    }

    func updateProgressReport(_ progressReport: TerminalProgressReport) {
        scheduleProgressReportExpiry(for: progressReport)
        writeProgressReportThrottled(progressReport)
    }

    /// Invalidates any pending auto-clear and, for a report that's still
    /// visible, re-arms a fresh one. See `progressReportExpiryWorkItem`.
    private func scheduleProgressReportExpiry(for progressReport: TerminalProgressReport) {
        progressReportExpiryWorkItem?.cancel()
        progressReportExpiryWorkItem = nil

        guard progressReport.isVisible else {
            return
        }

        let sessionID = sessionID
        let paneID = paneID
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.progressReportExpiryWorkItem = nil
                // `update(session:pane:...)` can re-point this NSView at a
                // different pane while the timer was pending — only clear
                // the pane that actually armed it.
                guard
                    ProgressReportDispatchGuard.shouldApply(
                        capturedSessionID: sessionID,
                        capturedPaneID: paneID,
                        currentSessionID: self.sessionID,
                        currentPaneID: self.paneID
                    )
                else { return }
                self.updateProgressReport(TerminalProgressReport(state: .remove))
            }
        }
        progressReportExpiryWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.progressReportExpiryInterval,
            execute: workItem
        )
    }

    /// Trailing-edge rate limit for the actual store write. See
    /// `ProgressReportWriteThrottle`.
    private func writeProgressReportThrottled(_ progressReport: TerminalProgressReport) {
        let now = CACurrentMediaTime()
        switch ProgressReportWriteThrottle.decide(
            now: now,
            lastWriteAt: lastProgressReportStoreWriteAt,
            minInterval: Self.progressReportStoreWriteMinInterval
        ) {
        case .writeNow:
            progressReportThrottleWorkItem?.cancel()
            progressReportThrottleWorkItem = nil
            commitProgressReport(progressReport, writtenAt: now)
        case .deferBy(let delay):
            scheduleThrottledProgressReportWrite(progressReport, after: delay)
        }
    }

    /// Replaces any prior pending write so only the LATEST report lands when
    /// the window closes — a fast finish (…97%, 100%, remove) can't have its
    /// terminal state dropped by an earlier tick's deferred write.
    private func scheduleThrottledProgressReportWrite(
        _ progressReport: TerminalProgressReport,
        after delay: TimeInterval
    ) {
        progressReportThrottleWorkItem?.cancel()

        let sessionID = sessionID
        let paneID = paneID
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.progressReportThrottleWorkItem = nil
                // Same pane-recycle hazard as the expiry timer above.
                guard
                    ProgressReportDispatchGuard.shouldApply(
                        capturedSessionID: sessionID,
                        capturedPaneID: paneID,
                        currentSessionID: self.sessionID,
                        currentPaneID: self.paneID
                    )
                else { return }
                self.commitProgressReport(progressReport, writtenAt: CACurrentMediaTime())
            }
        }
        progressReportThrottleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func commitProgressReport(_ progressReport: TerminalProgressReport, writtenAt: TimeInterval) {
        lastProgressReportStoreWriteAt = writtenAt
        sessionStore.updatePane(
            sessionID: sessionID,
            paneID: paneID,
            progressReport: progressReport
        )
    }

    func markNeedsAttention() {
        guard
            Self.shouldMarkGenericOutputNeedsAttention(
                isKeyWindow: window?.isKeyWindow == true,
                isSelectedWorkspace: sessionStore.selectedSessionID == sessionID
            )
        else {
            return
        }

        sessionStore.markSessionNeedsAttention(
            id: sessionID,
            paneID: paneID,
            unreadNotificationDelta: 1
        )
    }

    nonisolated static func shouldMarkGenericOutputNeedsAttention(
        isKeyWindow: Bool,
        isSelectedWorkspace: Bool
    ) -> Bool {
        !(isKeyWindow && isSelectedWorkspace)
    }

    func handleCommandFinished(exitCode: Int16) {
        // Cache the exit code for `closeAfterProcessExit` to consult. This event
        // fires after every shell command, so process-exit supervision must wait
        // for libghostty's separate close callback.
        commandExitCache.record(
            exitCode: exitCode,
            at: Date().timeIntervalSinceReferenceDate
        )

        let isShellSession = session.layout.pane(id: paneID)?.agentKind == .shell
        if isShellSession {
            shellCommandFinishedIdleLatched = true
        }
        runtime.refreshShellActivity(in: sessionStore)
        if isShellSession {
            runtime.scheduleShellActivityRefreshAfterCommandFinished(for: paneID, in: sessionStore)
        }

        // A successful command in a pane whose execution state is `.error`
        // clears the stale indicator. Gated on execution state so attention's
        // `.needsAttention` display projection does not hide a stale error.
        // Drop the event entirely if the session was removed between the
        // libghostty callback and this read.
        guard let liveSession = sessionStore.session(id: sessionID) else {
            return
        }
        let livePane = liveSession.layout.pane(id: paneID)
        let liveExecutionState = livePane?.agentExecutionState ?? .idle
        let liveAgentKind = livePane?.agentKind ?? .shell
        let detectorResult = agentOutputDetector.stateForCommandFinished(
            exitCode: exitCode,
            agentWasActive: hasObservedAgentActivity,
            liveAgentKind: liveAgentKind
        )
        switch handleCommandFinishedReducer.decision(
            liveExecutionState: liveExecutionState,
            exitCode: exitCode,
            detectorResult: detectorResult,
            liveAgentKind: liveAgentKind
        ) {
        case .clearStaleError:
            handleStaleErrorCleared()
        case .applyDetectedState(let detectedState):
            applyDetectedAgentState(detectedState)
        case .noop:
            break
        }
    }

    /// Side effects for the `.clearStaleError` decision: drop the red error
    /// indicator and announce the change to assistive technology. Centralized
    /// so any future `.error → .idle` follow-up has a single edit site.
    func handleStaleErrorCleared() {
        clearStaleErrorState()
        TerminalAccessibilityAnnouncer.announceErrorCleared()
    }

    /// Drop the cached exit code and the store's sticky `.error` flag together.
    /// Called from every path that transitions a session OUT of `.error` —
    /// otherwise a stale non-zero cached exit code from this morning's
    /// failed build can resurrect the red paint when a later close fires
    /// without its own `command_finished` (login wrappers, surfaces that lose
    /// shell integration mid-session).
    func clearStaleErrorState() {
        commandExitCache.clear()
        sessionStore.clearStaleErrorIfPresent(id: sessionID, paneID: paneID)
    }

    /// Minimum gap between visible-text diff checks. Named (not an inline
    /// `0.5`) because `scheduleAccessibilityValueChangeAnnouncement()`'s
    /// debounce window must stay comfortably longer than this — otherwise
    /// consecutive sampler ticks during sustained streaming output each
    /// independently fire a notification instead of collapsing into one.
    static let visibleTextChangeThrottle: TimeInterval = 0.5

    func sampleAgentStateFromVisibleText() {
        let now = CACurrentMediaTime()
        guard now - lastAgentDetectionSample >= Self.visibleTextChangeThrottle,
            let visibleText = visibleTerminalText()
        else {
            return
        }

        lastAgentDetectionSample = now
        guard visibleText != lastDetectedVisibleText else {
            return
        }

        lastDetectedVisibleText = visibleText

        // Visible content changed since the last sample and since the last
        // VoiceOver post: let assistive technology know there's something
        // new to read. This piggybacks on the sampler's existing text diff
        // rather than adding a second poll loop — see
        // `scheduleAccessibilityValueChangeAnnouncement()`. Scoped to the
        // FOCUSED pane only — mirrors `markNeedsAttention`'s
        // isKeyWindow/isSelectedWorkspace gating a few lines up. Without
        // this, a background pane streaming output (a build log, an agent
        // response) would interrupt VoiceOver reading a different, focused
        // pane every time its own content changed.
        if visibleText != lastAccessibilityReportedVisibleText {
            lastAccessibilityReportedVisibleText = visibleText
            if terminalIsFocused {
                scheduleAccessibilityValueChangeAnnouncement()
            }
        }

        hasObservedAgentActivity =
            hasObservedAgentActivity
            || agentOutputDetector.observesAgentContext(in: visibleText)

        // Visible-text changed: the underlying process is producing output.
        // Mark this as agent activity even if no state transition follows,
        // so a long-running `.thinking` task keeps its quit-risk freshness.
        // Conversely, when the process exits and text stops changing, no
        // marks happen and the staleness threshold catches the dead state.
        if hasObservedAgentActivity {
            sessionStore.markAgentActivityObserved(id: sessionID, paneID: paneID)
        }

        let liveKindForGate =
            sessionStore.session(id: sessionID)?
            .layout.pane(id: paneID)?.agentKind ?? .shell
        guard
            VisibleTextAgentStateReducer.shouldRunVisibleTextDetector(
                now: now,
                lastRuntimeEventAppliedAt: lastRuntimeEventAppliedAt,
                liveAgentKind: liveKindForGate
            )
        else {
            return
        }

        guard
            let detection = agentOutputDetector.detectedOutput(
                in: visibleText,
                assumingAgentContext: hasObservedAgentActivity
            )
        else {
            return
        }

        hasObservedAgentActivity = true
        if shouldSuppressVisibleTextState(detection.state, now: now) {
            return
        }
        applyDetectedAgentOutput(detection)
    }

    func shouldSuppressVisibleTextState(_ detectedState: AgentState, now: TimeInterval) -> Bool {
        visibleTextAgentStateReducer.shouldSuppressVisibleTextState(
            detectedState: detectedState,
            now: now,
            lastRuntimeEventAppliedAt: lastRuntimeEventAppliedAt,
            lastRuntimeAttentionEventAppliedAt: lastRuntimeAttentionEventAppliedAt,
            liveDisplayState: Self.visibleTextSuppressionLiveState(
                in: sessionStore.session(id: sessionID),
                paneID: paneID
            )
        )
    }

    /// The live display state visible-text suppression compares against: THIS
    /// pane's own state, never the session's loudest-pane fold. A sibling pane
    /// already needing attention must not mask this pane detecting its own
    /// `.needsAttention` (M4 / INT-504 review).
    static func visibleTextSuppressionLiveState(
        in session: TerminalSession?,
        paneID: TerminalPane.ID
    ) -> AgentState? {
        session?.layout.pane(id: paneID)?.agentState
    }

    func visibleTerminalText() -> String? {
        guard let surface else {
            return nil
        }

        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        )
        guard ghostty_surface_read_text(surface, selection, &text) else {
            return nil
        }
        // ghostty_surface_read_text hands back C-owned text; release it with
        // Ghostty's matching free API after a successful read.
        defer { ghostty_surface_free_text(surface, &text) }

        return String(cString: text.text)
    }

    func applyDetectedAgentState(_ detectedState: AgentState) {
        applyDetectedAgentOutput(AgentOutputDetection(state: detectedState))
    }

    func applyDetectedAgentOutput(_ detection: AgentOutputDetection) {
        // Drop late detector ticks that arrive after the session has been
        // closed/removed from the store. Without this guard, the announcement
        // posts even though the store mutation would no-op below — speaking a
        // transition that didn't actually happen.
        guard let liveSession = sessionStore.session(id: sessionID) else {
            return
        }
        // Grok's Settings opt-in gates both installed hooks and text identity;
        // when off, a detected `grok` session must not adopt the Grok kind.
        // Strip only the kind here so non-Grok state cues keep flowing.
        var detection = detection
        if detection.agentKind == .grok, !grokIconEnabled {
            detection.agentKind = nil
        }
        if detection.agentKind == .openCode,
            !enabledAgentRuntimeFileDropSources.contains(.openCode)
        {
            detection.agentKind = nil
        }
        let livePane = liveSession.layout.pane(id: paneID)
        let liveAgentKind = livePane?.agentKind ?? .shell
        let liveDisplayState = livePane?.agentState ?? .idle
        let liveExecutionState = livePane?.agentExecutionState ?? .idle
        let decision = visibleTextAgentStateReducer.visibleTextDecision(
            detectedState: detection.state,
            detectedAgentKind: detection.agentKind,
            detectedKindIsAuthoritative: detection.agentKindIsAuthoritative,
            liveAgentKind: liveAgentKind,
            liveExecutionState: liveExecutionState,
            liveDisplayState: liveDisplayState,
            terminalIsActiveForAttention: sessionIsSelectedInKeyWindow || terminalIsFocused
        )
        guard decision.shouldApply else {
            return
        }

        // Grok can clear sticky thinking via identity-only waiting, but only when
        // the shell is quiet — mid-turn pure inference may drop live cues while
        // tools are still about to run; busy shell keeps the thinking chrome.
        var applyState = decision.shouldApplyState ? detection.state : nil
        if applyState == .waiting,
            liveAgentKind == .grok,
            (liveExecutionState == .thinking || liveDisplayState == .thinking),
            livePane?.shellActivity == .busy
        {
            applyState = nil
            if decision.agentKind == nil {
                return
            }
        }

        if decision.shouldClearStaleError {
            clearStaleErrorState()
        }
        if applyState != nil || decision.agentKind != nil {
            announce(decision.announcementIntent)
        }

        sessionStore.applyDetectedAgentState(
            id: sessionID,
            paneID: paneID,
            detectedState: applyState,
            agentKind: decision.agentKind,
            clearsAttention: applyState != nil ? decision.clearsAttention : false,
            clearsUnreadNotifications: applyState != nil ? decision.clearsUnreadNotifications : false,
            unreadNotificationDelta: applyState != nil ? decision.unreadNotificationDelta : 0
        )
    }

    func announce(_ intent: AgentStateAnnouncementIntent) {
        switch intent {
        case .errorEntered:
            TerminalAccessibilityAnnouncer.announceErrorEntered()
        case .errorCleared:
            TerminalAccessibilityAnnouncer.announceErrorCleared()
        case .errorClearedAndWaiting:
            TerminalAccessibilityAnnouncer.announceErrorClearedAndWaitingForInput(
                sessionTitle: liveSessionTitle(),
                paneDescriptor: livePaneDescriptorForAnnouncement()
            )
        case .waitingEntered:
            TerminalAccessibilityAnnouncer.announceWaitingForInput(
                sessionTitle: liveSessionTitle(),
                paneDescriptor: livePaneDescriptorForAnnouncement()
            )
        case .none:
            break
        }
    }

    private func liveSessionTitle() -> String {
        sessionStore.session(id: sessionID)?.title ?? ""
    }

    /// Pane identity is only spoken when the session has multiple terminal
    /// panes — in a single-pane session it would just repeat the session
    /// context as noise. The tree-order ordinal is the guaranteed
    /// discriminator (pane titles can be duplicated or blank by design); the
    /// title is appended when present as the human-friendly half.
    private func livePaneDescriptorForAnnouncement() -> String? {
        guard let session = sessionStore.session(id: sessionID) else {
            return nil
        }
        let panes = session.panes
        guard panes.count > 1,
            let index = panes.firstIndex(where: { $0.id == paneID })
        else {
            return nil
        }
        let title = panes[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "pane \(index + 1)" : "pane \(index + 1), \(title)"
    }

    func applyAgentRuntimeEvent(_ event: AgentRuntimeEvent) {
        guard AgentRuntimeConsent(enabledFileDropSources: enabledAgentRuntimeFileDropSources).allows(event) else {
            return
        }

        // `.rename` events flow through the same `sessionStore.applyAgentRuntimeEvent`
        // path as state events now — the reducer resolves them to a pane-title
        // action AFTER the (eventID, timestamp) dedupe + staleness guards, so a
        // replayed/out-of-order rename can't overwrite a newer title. (It used to
        // bypass the reducer here.) The title-only contract + nil-title-drop now
        // live in the reducer.

        // Capture the pre-apply state so we can fire VoiceOver announcements
        // that match the detector-driven path. Read THIS pane's state, not the
        // session-level loudest-pane fold: the event mutates one pane, so a
        // sibling pane holding a louder state would otherwise mask this pane's
        // error transition and the announcement (and `clearStaleErrorState`)
        // would never fire (INT-504 — matches the per-pane detector path).
        let priorState = sessionStore.session(id: sessionID)?
            .layout.pane(id: paneID)?.agentState
        let applied = sessionStore.applyAgentRuntimeEvent(
            event,
            to: sessionID,
            paneID: paneID,
            terminalIsFocused: terminalIsFocused
        )
        guard applied else { return }

        // Session end returns the pane to plain shell, so drop the agent-
        // context latch too: with it armed, an ordinary shell command's
        // nonzero exit would flow through stateForCommandFinished(agentWasActive:
        // true) and paint agent done/error chrome on a pane that no longer
        // hosts an agent — chrome a never-agent shell pane never gets
        // (cross-model review, INT-552). Leftover on-screen agent markers can
        // legitimately re-arm the latch via observesAgentContext; that is the
        // visible-text heuristic's own scope, not suppressed here.
        if event.phase == .sessionEnd {
            hasObservedAgentActivity = false
        }

        // Only state-bearing events suppress the visible-text detector,
        // and only after the store actually accepted the event — a
        // rejected dedupe/stale event shouldn't mute the fallback.
        let suppressionDecision =
            visibleTextAgentStateReducer
            .runtimeEventSuppressionDecision(
                state: event.state,
                executionState: event.executionState,
                attentionReason: event.attentionReason
            )
        if suppressionDecision.shouldRecordStateEvent {
            let appliedAt = CACurrentMediaTime()
            lastRuntimeEventAppliedAt = appliedAt
            if suppressionDecision.shouldRecordAttentionEvent {
                lastRuntimeAttentionEventAppliedAt = appliedAt
            }
        }

        // Mirror the detector-path accessibility announcements for error
        // transitions so VoiceOver users hear the same signal regardless
        // of which channel produced the state change. The needsAttention
        // path owns its own announcement (see applyDetectedAgentState).
        let newState = sessionStore.session(id: sessionID)?
            .layout.pane(id: paneID)?.agentState
        // Trusted-generation stamp for the document-nudge prompt gate
        // (INT-569 follow-up): this is the ONLY path that may set
        // `verifiedWaitingForegroundIncarnation`, and only for an event that
        // ITSELF asserts `.waiting` (`assertsWaitingExecutionState`) — not
        // merely because the pane's resulting display state happens to
        // already read `.waiting`. Without the assertion check, ANY accepted
        // event on an already-`.waiting` pane (a title-only `.rename`, a
        // tool-lifecycle event, a same-state repeat) would re-sample and
        // re-stamp trust for whatever process is CURRENTLY foreground — even
        // though that event proved nothing about it, reopening exactly the
        // relaunch spoof window this gate exists to close (review finding).
        //
        // A hook moving the pane away from `.waiting` clears the stamp, so a
        // later detector-only re-affirmation of `.waiting` can't inherit
        // stale trust. Anything else (an accepted, non-asserting event while
        // the pane is still legitimately `.waiting`) leaves the existing
        // trusted generation untouched — `verdict` re-checks it against the
        // CURRENT foreground process at click time regardless.
        if event.assertsWaitingExecutionState, newState == .waiting {
            verifiedWaitingForegroundIncarnation = documentNudgeForegroundGeneration()
        } else if newState != .waiting {
            verifiedWaitingForegroundIncarnation = nil
        }
        let announcementIntent = visibleTextAgentStateReducer.announcementIntent(
            priorDisplayState: priorState,
            newDisplayState: newState
        )
        if announcementIntent.clearsStaleError {
            clearStaleErrorState()
        }
        announce(announcementIntent)
    }

    func markNeedsAttentionPromptAnswered() {
        let livePane =
            sessionStore.session(id: sessionID)?.layout.pane(id: paneID)
            ?? session.layout.pane(id: paneID)
        guard livePane?.agentState == .needsAttention else {
            return
        }

        sessionStore.markNeedsAttentionPromptAnswered(id: sessionID, paneID: paneID)
    }
}
