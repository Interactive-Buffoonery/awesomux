import Foundation

extension SessionStore {
    public struct CommandBridgePaneHealResult: Equatable, Sendable {
        public let sessionID: TerminalSession.ID
        public let pane: TerminalPane

        public var paneID: TerminalPane.ID { pane.id }
        public var terminalSessionID: TerminalSessionID { pane.terminalSessionID }
    }

    /// Renames a session without exposing the generic internal session reducer.
    public func renameSession(id: TerminalSession.ID, title: String) {
        guard let position = position(for: id) else { return }
        let now = Date()
        let change = WorkspaceAttentionReducer.updatePane(
            &_groups[position.groupIndex].sessions[position.sessionIndex],
            paneID: _groups[position.groupIndex].sessions[position.sessionIndex].activePaneID,
            update: WorkspaceAttentionReducer.SessionUpdate(title: title),
            now: now
        )
        commit(WorkspaceMutationEffect(unreadChange: change), now: now)
    }

    /// Sets or clears a workspace's per-workspace notification mute (INT-598).
    /// Muting gates only the interruptive channels (macOS banner + sound);
    /// sidebar indicators, unread badges, and the dock badge are unaffected.
    /// Idempotent: returns true when the session exists, false otherwise.
    @discardableResult
    public func setNotificationsMuted(
        id: TerminalSession.ID,
        muted: Bool
    ) -> Bool {
        guard let position = position(for: id) else { return false }
        guard _groups[position.groupIndex].sessions[position.sessionIndex]
            .notificationsMuted != muted else {
            return true
        }
        _groups[position.groupIndex].sessions[position.sessionIndex]
            .notificationsMuted = muted
        return true
    }

    /// All workspaces with per-workspace notification mute enabled, in sidebar
    /// order — feeds the Settings → Notifications muted-workspace list.
    public var mutedNotificationSessions: [TerminalSession] {
        _groups.flatMap(\.sessions).filter(\.notificationsMuted)
    }

    /// Pins a custom title on a specific pane (the four rename entry points all
    /// land here). Distinct from `updatePane(title:)`, which is the live OSC
    /// path and must never set the user-edited freeze.
    @discardableResult
    public func renamePane(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        title: String
    ) -> Bool {
        guard let position = position(for: sessionID),
              let session = PaneLayoutReducer.renamePane(
                  in: _groups[position.groupIndex].sessions[position.sessionIndex],
                  paneID: paneID,
                  title: title
              ) else {
            return false
        }
        _groups[position.groupIndex].sessions[position.sessionIndex] = session
        return true
    }

    /// Clears a pane's custom-title freeze and re-adopts the live terminal title.
    @discardableResult
    public func resetPaneTitle(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID
    ) -> Bool {
        guard let position = position(for: sessionID),
              let session = PaneLayoutReducer.resetPaneTitle(
                  in: _groups[position.groupIndex].sessions[position.sessionIndex],
                  paneID: paneID
              ) else {
            return false
        }
        _groups[position.groupIndex].sessions[position.sessionIndex] = session
        return true
    }

    /// Sets or clears a pane's name-plate color. `nil` clears to default chrome.
    ///
    /// Returns true when the pane exists — whether or not the color changed
    /// (idempotent success), matching `setGroupColor`'s contract. Returns false
    /// only when the session or pane is absent.
    @discardableResult
    public func setPaneColor(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        color: PaneColor?
    ) -> Bool {
        guard let position = position(for: sessionID) else { return false }
        let currentSession = _groups[position.groupIndex].sessions[position.sessionIndex]
        guard currentSession.layout.pane(id: paneID) != nil else { return false }
        // Reducer returns nil when nothing changed — skip churn but still report success.
        if let updated = PaneLayoutReducer.setPaneColor(
            in: currentSession,
            paneID: paneID,
            color: color
        ) {
            _groups[position.groupIndex].sessions[position.sessionIndex] = updated
        }
        return true
    }

    /// Marks a pane as needing attention. Public unread deltas only add badges.
    /// `paneID` defaults to the session's active pane.
    public func markSessionNeedsAttention(
        id: TerminalSession.ID,
        paneID: TerminalPane.ID? = nil,
        unreadNotificationDelta: Int = 1
    ) {
        applyPaneUpdate(
            sessionID: id,
            paneID: paneID,
            update: WorkspaceAttentionReducer.SessionUpdate(
                agentState: .needsAttention,
                unreadNotificationDelta: normalizedPublicUnreadDelta(unreadNotificationDelta)
            )
        )
    }

    public func updatePermissionPromptAttention(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        countDelta: Int,
        hasPending: Bool
    ) {
        guard let position = position(for: sessionID) else { return }
        let change = WorkspaceAttentionReducer.updatePermissionPromptAttention(
            &_groups[position.groupIndex].sessions[position.sessionIndex],
            paneID: paneID,
            countDelta: countDelta,
            hasPending: hasPending
        )
        commit(WorkspaceMutationEffect(unreadChange: change))
    }

    /// Applies visible-text detector state to a pane. Public unread deltas only
    /// add badges. `paneID` defaults to the session's active pane.
    public func applyDetectedAgentState(
        id: TerminalSession.ID,
        paneID: TerminalPane.ID? = nil,
        detectedState: AgentState?,
        agentKind: AgentKind? = nil,
        clearsAttention: Bool,
        clearsUnreadNotifications: Bool = false,
        unreadNotificationDelta: Int = 0
    ) {
        applyPaneUpdate(
            sessionID: id,
            paneID: paneID,
            update: WorkspaceAttentionReducer.SessionUpdate(
                agentKind: agentKind,
                agentState: detectedState,
                clearsAttention: clearsAttention,
                clearsUnreadNotifications: clearsUnreadNotifications,
                unreadNotificationDelta: normalizedPublicUnreadDelta(unreadNotificationDelta)
            )
        )
    }

    /// Marks an answered prompt as thinking again, on the given pane.
    ///
    /// No-ops unless that pane is currently `.needsAttention`. When it applies,
    /// the pane transitions to `.thinking`, clears attention, and clears its
    /// unread badge because the user has acted on that prompt. `paneID` defaults
    /// to the session's active pane.
    public func markNeedsAttentionPromptAnswered(
        id: TerminalSession.ID,
        paneID: TerminalPane.ID? = nil
    ) {
        guard let targetPaneID = resolvedPaneID(sessionID: id, paneID: paneID),
              session(id: id)?.layout.pane(id: targetPaneID)?.agentState == .needsAttention else {
            return
        }
        applyPaneUpdate(
            sessionID: id,
            paneID: targetPaneID,
            update: WorkspaceAttentionReducer.SessionUpdate(
                agentState: .thinking,
                clearsAttention: true,
                clearsUnreadNotifications: true
            )
        )
    }

    #if DEBUG
    public func setDebugAgentState(
        id: TerminalSession.ID,
        paneID: TerminalPane.ID? = nil,
        agentState: AgentState,
        clearsAttention: Bool = false,
        unreadNotificationDelta: Int = 0
    ) {
        applyPaneUpdate(
            sessionID: id,
            paneID: paneID,
            update: WorkspaceAttentionReducer.SessionUpdate(
                agentState: agentState,
                clearsAttention: clearsAttention,
                unreadNotificationDelta: normalizedPublicUnreadDelta(unreadNotificationDelta)
            )
        )
    }
    #endif

    private func normalizedPublicUnreadDelta(_ delta: Int) -> Int {
        max(0, delta)
    }

    /// Resolves a target pane, defaulting to the session's active pane.
    func resolvedPaneID(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID?
    ) -> TerminalPane.ID? {
        guard let position = position(for: sessionID) else { return nil }
        let session = _groups[position.groupIndex].sessions[position.sessionIndex]
        if let paneID, session.layout.pane(id: paneID) != nil {
            return paneID
        }
        return session.activePaneID
    }

    @discardableResult
    private func applyPaneUpdate(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID?,
        update: WorkspaceAttentionReducer.SessionUpdate,
        now: Date = Date()
    ) -> Bool {
        guard let position = position(for: sessionID),
              let targetPaneID = resolvedPaneID(sessionID: sessionID, paneID: paneID) else {
            return false
        }
        let change = WorkspaceAttentionReducer.updatePane(
            &_groups[position.groupIndex].sessions[position.sessionIndex],
            paneID: targetPaneID,
            update: update,
            now: now
        )
        commit(
            WorkspaceMutationEffect(
                unreadChange: change,
                riskSessionIDs: [sessionID]
            ),
            now: now
        )
        return true
    }

    /// Records that the pane `exitingPaneID` exited with an error. Resolution is
    /// STRICT: the error lands on that exact pane, never a fallback. If the pane
    /// is already gone from the layout — the common case, since `closePane`
    /// removes the dead pane and promotes a sibling to active before this fires —
    /// there is no held-dead pane yet (INT-506), so the error has nowhere to live
    /// and this no-ops rather than badging an innocent surviving sibling
    /// (INT-504 R7 / M2). Returns whether the error was recorded.
    @discardableResult
    public func recordSiblingPaneExitError(
        in sessionID: TerminalSession.ID,
        exitingPaneID: TerminalPane.ID,
        terminalIsFocused: Bool
    ) -> Bool {
        guard let position = position(for: sessionID),
              session(id: sessionID)?.layout.pane(id: exitingPaneID) != nil else {
            return false
        }
        let change = WorkspaceAttentionReducer.recordPaneExitError(
            &_groups[position.groupIndex].sessions[position.sessionIndex],
            paneID: exitingPaneID,
            terminalIsFocused: terminalIsFocused
        )
        commit(WorkspaceMutationEffect(unreadChange: change))
        return true
    }

    /// Records a recoverable process/backend failure on an existing pane without
    /// closing or recycling it. Used when a persistent-session attach client can
    /// no longer prove that its daemon session exists.
    ///
    /// Remote-group panes additionally latch `remoteReconnect = .disconnected`
    /// (INT-697), driving the reconnect overlay; local (nil-target) deaths
    /// leave it nil since there's no host to reconnect to. `SessionUpdate` has
    /// no field for this and shouldn't grow one for this single caller, so it's
    /// a direct pane mutation after the reducer call, same as
    /// `healCommandBridgePaneInPlace`/`updateTerminalBackendMetadata`.
    @discardableResult
    public func recordPaneProcessError(
        in sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        terminalIsFocused: Bool
    ) -> Bool {
        guard let position = position(for: sessionID),
              let pane = session(id: sessionID)?.layout.pane(id: paneID) else {
            return false
        }
        // Snapshot BEFORE the reducer flips the pane to `.error`: this records
        // whether the latch actually displaced a non-error pane, so recovery
        // only resets `.error` when the bridge death (not agent output) set it
        // (INT-697 fix #2).
        let displacedNonErrorState = pane.agentExecutionState != .error
        let now = Date()
        let change = WorkspaceAttentionReducer.updatePane(
            &_groups[position.groupIndex].sessions[position.sessionIndex],
            paneID: paneID,
            update: WorkspaceAttentionReducer.SessionUpdate(
                agentExecutionState: .error,
                clearsAttention: true,
                unreadNotificationDelta: !terminalIsFocused
                    && displacedNonErrorState ? 1 : 0
            ),
            now: now
        )

        if let target = pane.executionPlan.remoteTarget {
            mutatePane(sessionID: sessionID, paneID: paneID) { errorPane in
                errorPane.remoteReconnect = .disconnected(
                    .init(target: target, displacedNonErrorState: displacedNonErrorState)
                )
            }
        }

        commit(
            WorkspaceMutationEffect(
                unreadChange: change,
                riskSessionIDs: [sessionID]
            ),
            now: now
        )
        return true
    }

    /// Clears a pane's reconnect affordance on confirmed attach — the
    /// `attached` status event, the same signal the command-bridge heal path
    /// already trusts (INT-697). A same-incarnation manual reconnect never
    /// routes through `resetPaneAgentChromeToShell` (that would wipe the agent
    /// identity a reconnect is meant to preserve), so this is the only place
    /// that un-sticks a bridge-death `.error` after a successful reconnect —
    /// reset to the pane's kind-appropriate idle state, not a hardcoded shell
    /// reset. No-ops (returns false) when nothing was latched, so an ordinary
    /// attach that never went through `.disconnected`/`.reconnecting` is
    /// unaffected.
    @discardableResult
    public func confirmPaneRemoteReconnected(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID
    ) -> Bool {
        guard session(id: sessionID)?.layout.pane(id: paneID)?.remoteReconnect != nil else {
            return false
        }

        let changed = mutatePane(sessionID: sessionID, paneID: paneID) { pane in
            _ = self.clearingRemoteReconnect(&pane)
        }
        guard changed else { return false }

        let now = Date()
        commit(
            WorkspaceMutationEffect(riskSessionIDs: [sessionID]),
            now: now
        )
        return true
    }

    /// Clears a pane's reconnect overlay state and, when the latch had displaced
    /// a *non-error* pane, resets `.error` to the kind-appropriate idle state
    /// (NOT a hardcoded shell reset — a same-incarnation reconnect preserves the
    /// agent identity). Shared by the status-driven confirm and the heal recovery
    /// paths (INT-697 fix #1/#2). Returns whether anything changed.
    @discardableResult
    private func clearingRemoteReconnect(_ pane: inout TerminalPane) -> Bool {
        guard let state = pane.remoteReconnect else { return false }
        pane.remoteReconnect = nil
        if pane.agentExecutionState == .error, state.context.displacedNonErrorState {
            pane.agentExecutionState = pane.agentKind.initialSessionState.executionState ?? .idle
        }
        return true
    }

    /// Fetch → mutate → reinsert a single pane by id, rebuilding the layout tree.
    /// Returns false when the session/pane is absent or the layout can't be
    /// rebuilt. The INT-697 reconnect setters share this exact shape.
    @discardableResult
    private func mutatePane(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        _ transform: (inout TerminalPane) -> Void
    ) -> Bool {
        guard let position = position(for: sessionID),
              var pane = session(id: sessionID)?.layout.pane(id: paneID) else {
            return false
        }
        transform(&pane)
        guard let layout = _groups[position.groupIndex].sessions[position.sessionIndex]
            .layout.replacingPane(id: paneID, with: .pane(pane)) else {
            return false
        }
        _groups[position.groupIndex].sessions[position.sessionIndex].layout = layout
        return true
    }

    /// Flips a latched `.disconnected` pane to `.reconnecting`, keeping the
    /// captured target unchanged, right before a manual respawn attempt
    /// (`CommandBridgeEnactor.beginManualReconnect`, INT-697). No-ops when the
    /// pane isn't currently `.disconnected` — doubles as the idempotence guard
    /// against a racing second click.
    @discardableResult
    public func markPaneRemoteReconnecting(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID
    ) -> Bool {
        guard case let .disconnected(context)? = session(id: sessionID)?
            .layout.pane(id: paneID)?.remoteReconnect else {
            return false
        }

        // Refresh from the pane's durable execution plan at dial time so the
        // recovery announcement names the host this pane actually dials.
        var newContext = context
        if let liveTarget = session(id: sessionID)?.layout.pane(id: paneID)?
            .executionPlan.remoteTarget
        {
            newContext.target = liveTarget
            newContext.dialedLocalRestart = false
        } else {
            newContext.dialedLocalRestart = true
        }

        return mutatePane(sessionID: sessionID, paneID: paneID) { pane in
            pane.remoteReconnect = .reconnecting(newContext)
        }
    }

    /// Clears a pane's agent identity back to shell defaults (agentKind = .shell,
    /// execution state = shell initial state, attentionReason = nil) without
    /// touching title, cwd, terminalSessionID, or backend metadata. Called when
    /// the command-bridge detects a fresh daemon incarnation so a respawned shell
    /// doesn't inherit the dead incarnation's agent chrome.
    @discardableResult
    public func resetPaneAgentChromeToShell(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID
    ) -> Bool {
        guard let position = position(for: sessionID),
              let session = PaneLayoutReducer.resetPaneAgentChromeToShell(
                  in: _groups[position.groupIndex].sessions[position.sessionIndex],
                  paneID: paneID
              ) else {
            return false
        }
        _groups[position.groupIndex].sessions[position.sessionIndex] = session
        commit(WorkspaceMutationEffect(needsFullRebuild: true))
        return true
    }

    /// Prepares an existing bridged pane for an in-place runtime reattach.
    ///
    /// This intentionally does not call `closePane`, recycle the pane, change
    /// focus, or rebuild the layout tree. The app-target surface lifecycle will
    /// consume the returned `terminalSessionID` by creating a fresh `amx attach`
    /// surface for the same pane identity.
    @discardableResult
    public func healCommandBridgePaneInPlace(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        metadata: TerminalBackendMetadata
    ) -> CommandBridgePaneHealResult? {
        guard let position = position(for: sessionID),
              var pane = session(id: sessionID)?.layout.pane(id: paneID) else {
            return nil
        }

        var changed = false
        if pane.terminalBackendMetadata != metadata {
            pane.terminalBackendMetadata = metadata
            changed = true
        }
        // Fold the reconnect-overlay clear in here so BOTH heal call sites (the
        // legacy exit-recovery branch and the status-driven respawn/reconnect)
        // un-stick a latched remote pane. The status `.attached` confirm covers
        // the manual reconnect path, but degraded mode — the status channel
        // failed to mint — recovers ONLY through heal, so without this the
        // overlay would sit "Reconnecting…" forever over a healthy pane
        // (INT-697 fix #1).
        let clearedReconnect = clearingRemoteReconnect(&pane)
        changed = changed || clearedReconnect

        if changed {
            guard let layout = _groups[position.groupIndex].sessions[position.sessionIndex]
                .layout
                .replacingPane(id: paneID, with: .pane(pane)) else {
                return nil
            }
            _groups[position.groupIndex].sessions[position.sessionIndex].layout = layout
            // A cleared `.error` changes quit-risk membership.
            if clearedReconnect {
                commit(WorkspaceMutationEffect(riskSessionIDs: [sessionID]))
            }
        }

        return CommandBridgePaneHealResult(sessionID: sessionID, pane: pane)
    }

    @discardableResult
    public func updateTerminalBackendMetadata(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        metadata: TerminalBackendMetadata
    ) -> Bool {
        guard let position = position(for: sessionID),
              var pane = session(id: sessionID)?.layout.pane(id: paneID) else {
            return false
        }

        guard pane.terminalBackendMetadata != metadata else {
            return true
        }

        pane.terminalBackendMetadata = metadata
        guard let layout = _groups[position.groupIndex].sessions[position.sessionIndex]
            .layout
            .replacingPane(id: paneID, with: .pane(pane)) else {
            return false
        }

        _groups[position.groupIndex].sessions[position.sessionIndex].layout = layout
        return true
    }

    @discardableResult
    public func applyAgentRuntimeEvent(
        _ event: AgentRuntimeEvent,
        to sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        terminalIsFocused: Bool = false
    ) -> Bool {
        let now = Date()
        guard let position = position(for: sessionID),
              let decision = runtimeEventReducer.decision(
                  for: event,
                  currentSession: session(id: sessionID),
                  paneID: paneID,
                  terminalIsFocused: terminalIsFocused,
                  now: now
              ) else {
            return false
        }
        // Two commits are intentional: unread must land before a nested
        // openDocumentPane full rebuild (so rebuild sees the tree's new badges),
        // and risk reclassify must run after titles/document side effects even
        // when that rebuild was a no-op dedupe (composition rule: multi-commit OK).
        if decision.appliesPaneUpdate {
            let change = WorkspaceAttentionReducer.updatePane(
                &_groups[position.groupIndex].sessions[position.sessionIndex],
                paneID: paneID,
                update: decision.update,
                now: now
            )
            commit(WorkspaceMutationEffect(unreadChange: change), now: now)
        }

        // A `.rename` event resolves to a pane-title action that the reducer
        // already gated through dedupe + staleness; apply it to the same pane.
        switch decision.paneTitleAction {
        case .rename(let title):
            if let session = PaneLayoutReducer.renamePane(
                in: _groups[position.groupIndex].sessions[position.sessionIndex],
                paneID: paneID,
                title: title
            ) {
                _groups[position.groupIndex].sessions[position.sessionIndex] = session
            }
        case .reset:
            if let session = PaneLayoutReducer.resetPaneTitle(
                in: _groups[position.groupIndex].sessions[position.sessionIndex],
                paneID: paneID
            ) {
                _groups[position.groupIndex].sessions[position.sessionIndex] = session
            }
        case nil:
            break
        }

        switch decision.documentPaneAction {
        case .open(let url):
            // The event's pane is the document's terminal association — an
            // agent-opened document sends/stages back to the pane whose hook
            // opened it (INT-748).
            guard openDocumentPane(fileURL: url, in: sessionID, associatedWith: paneID) != nil else {
                return false
            }
        case nil:
            break
        }
        commit(
            WorkspaceMutationEffect(riskSessionIDs: [sessionID]),
            now: now
        )
        return true
    }

    public func updatePane(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        title: String? = nil,
        workingDirectory: String? = nil,
        progressReport: TerminalProgressReport? = nil
    ) {
        guard let position = position(for: sessionID) else {
            return
        }

        let oldSession = _groups[position.groupIndex].sessions[position.sessionIndex]
        let wasRemote = oldSession.layout.pane(id: paneID)?.remoteHost != nil
        guard let session = PaneLayoutReducer.updatePane(
            in: oldSession,
            paneID: paneID,
            title: title,
            workingDirectory: workingDirectory,
            progressReport: progressReport,
            localHostnames: localHostnames
        ) else {
            return
        }

        let isRemote = session.layout.pane(id: paneID)?.remoteHost != nil
        _groups[position.groupIndex].sessions[position.sessionIndex] = session
        var remoteMembership: [TerminalPane.ID: Bool] = [:]
        if isRemote {
            remoteMembership[paneID] = true
        } else if wasRemote {
            remoteMembership[paneID] = false
        }
        if !remoteMembership.isEmpty {
            commit(WorkspaceMutationEffect(remotePaneMembership: remoteMembership))
        }
    }

    public func noteSubmittedCommand(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        command: String
    ) {
        guard let position = position(for: sessionID),
              let session = PaneLayoutReducer.noteSubmittedCommand(
                in: _groups[position.groupIndex].sessions[position.sessionIndex],
                paneID: paneID,
                command: command
              )
        else {
            return
        }
        _groups[position.groupIndex].sessions[position.sessionIndex] = session
    }

    public func consumeManagedSSHWorkspaceOffer(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID
    ) -> RemoteTarget? {
        guard let rawTarget = session(id: sessionID)?.layout.pane(id: paneID)?.remoteSSHTarget,
            let target = RemoteTarget(parsing: rawTarget),
            target.isSafeSSHDestination,
            mutatePane(sessionID: sessionID, paneID: paneID, { $0.remoteSSHTarget = nil })
        else {
            return nil
        }
        return target
    }

    public func markRemotePanesPossiblyStale() {
        guard !index.remotePaneIDs.isEmpty else {
            return
        }

        for groupIndex in _groups.indices {
            for sessionIndex in _groups[groupIndex].sessions.indices {
                let result = _groups[groupIndex].sessions[sessionIndex].layout
                    .markingRemotePanesPossiblyStale()
                guard result.didChange else {
                    continue
                }
                _groups[groupIndex].sessions[sessionIndex].layout = result.layout
            }
        }
    }

    func position(for id: TerminalSession.ID) -> SessionStoreIndex.Position? {
        index.positionsBySessionID[id]
    }

    /// Sole derived-state repair path for migrated mutations (F30).
    ///
    /// Composition rules:
    /// - Synchronous, non-batching, reentrant-safe.
    /// - Multiple commits per public entry are expected (e.g. closeGroup →
    ///   closeSession×N → removeGroup; applyAgentRuntimeEvent → openDocumentPane
    ///   then later risk reclassify).
    /// - Nested public mutators that each commit are allowed; do not introduce
    ///   deferred/batched commit.
    /// - `now` is shared with reducer timestamps and DEBUG risk asserts (avoid
    ///   60s-boundary flakes, INT-420).
    /// - Selection `.set` is an unconditional write (INT-652).
    func commit(_ effect: WorkspaceMutationEffect, now: Date = Date()) {
        #if DEBUG
        precondition(
            !effect.needsFullRebuild || (
                effect.unreadChange == nil &&
                    effect.riskSessionIDs.isEmpty &&
                    effect.remotePaneMembership.isEmpty
            ),
            "Full-rebuild effects must not include incremental cache repairs"
        )
        #endif

        if effect.needsFullRebuild {
            rebuildDerivedState(now: now)
        } else {
            applyUnreadChange(effect.unreadChange)
            for (paneID, isRemote) in effect.remotePaneMembership {
                if isRemote {
                    index.remotePaneIDs.insert(paneID)
                } else {
                    index.remotePaneIDs.remove(paneID)
                }
            }
            for sessionID in effect.riskSessionIDs {
                reclassifyRiskMembership(sessionID: sessionID)
            }
            #if DEBUG
            if !effect.riskSessionIDs.isEmpty {
                assertQuitRiskCacheMatches(now: now)
            }
            #endif
        }

        if case .set(let sessionID) = effect.selection {
            // Unconditional write: same-value re-assign must still publish (INT-652).
            selectedSessionID = sessionID
        }
    }

    private func rebuildDerivedState(now: Date = Date()) {
        index = SessionStoreIndex.build(from: _groups)
        unreadNotificationTotal = index.unreadNotificationTotal
        shellActivityReducer.prune(livePaneIDs: index.livePaneIDs)
        runtimeEventReducer.prune(livePaneIDs: index.livePaneIDs)

        #if DEBUG
        let allIDs = _groups.flatMap { $0.sessions.map(\.id) }
        if Set(allIDs).count == allIDs.count {
            let computedTotal = _groups.reduce(0) { total, group in
                total + group.sessions.reduce(0) { $0 + $1.unreadNotificationCount }
            }
            assert(
                unreadNotificationTotal == computedTotal,
                "unreadNotificationTotal cache drift detected"
            )
        }
        assertQuitRiskCacheMatches(now: now)
        #endif

        // Prune pins to live sessions here — every structural mutation (close,
        // remove group, restore) routes through this rebuild, so no per-callsite
        // cleanup can be missed. Guarded write: @Observable fires on every set.
        if pinnedSessionIDs.contains(where: { index.positionsBySessionID[$0] == nil }) {
            pinnedSessionIDs.removeAll { index.positionsBySessionID[$0] == nil }
        }
    }

    func recordRecentlyClosed(_ entry: RecentlyClosedWorkspace, now: Date) {
        RecentlyClosedWorkspaceReducer.recordPersisted(
            entry,
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &lastClosedTransient,
            now: now
        )
    }

    private func applyUnreadChange(_ change: WorkspaceAttentionReducer.UnreadChange?) {
        guard let change else { return }
        unreadNotificationTotal += change.newCount - change.oldCount
    }

    /// Reclassifies one session after a mutation to the fields that
    /// `SessionStoreIndex.classifySessionRisk` reads. Keeping this private beside
    /// `commit` makes the transaction entry point the only cache writer.
    private func reclassifyRiskMembership(sessionID: TerminalSession.ID) {
        guard let position = position(for: sessionID) else {
            index.durableAtRiskSessionIDs.remove(sessionID)
            index.freshnessCandidateSessionIDs.remove(sessionID)
            return
        }
        switch SessionStoreIndex.classifySessionRisk(
            _groups[position.groupIndex].sessions[position.sessionIndex]
        ) {
        case .durable:
            index.durableAtRiskSessionIDs.insert(sessionID)
            index.freshnessCandidateSessionIDs.remove(sessionID)
        case .freshnessCandidate:
            index.durableAtRiskSessionIDs.remove(sessionID)
            index.freshnessCandidateSessionIDs.insert(sessionID)
        case .safe:
            index.durableAtRiskSessionIDs.remove(sessionID)
            index.freshnessCandidateSessionIDs.remove(sessionID)
        }
    }

    func scheduleAcknowledgementForSelectedSession() {
        let baseline: SelectionAcknowledgementBaseline?
        if let selectedSessionID,
           let position = position(for: selectedSessionID) {
            let session = _groups[position.groupIndex].sessions[position.sessionIndex]
            baseline = SelectionAcknowledgementBaseline(
                activePaneID: session.activePaneID,
                paneUnreadCount: session.layout.pane(id: session.activePaneID)?
                    .unreadNotificationCount ?? 0
            )
        } else {
            baseline = nil
        }

        acknowledgementCoordinator.schedule(
            selectedSessionID: selectedSessionID,
            baseline: baseline
        ) { [weak self] selectedSessionID, baseline in
            guard let self,
                  self.selectedSessionID == selectedSessionID,
                  let position = self.position(for: selectedSessionID) else {
                return
            }

            let current = self._groups[position.groupIndex].sessions[position.sessionIndex]
            // The dwell baselined on the active pane; if the active pane changed
            // mid-dwell the baseline no longer applies, so bail (INT-504 R3).
            guard current.activePaneID == baseline.activePaneID else {
                return
            }
            let currentPaneUnread = current.layout.pane(id: current.activePaneID)?
                .unreadNotificationCount ?? 0
            guard currentPaneUnread <= baseline.paneUnreadCount else {
                return
            }

            // Selection dwell acks the ACTIVE pane only — a sibling pane still
            // needing input keeps the workspace row loud (ADR-0003 amendment).
            self.acknowledgeSession(id: selectedSessionID)
        }
    }
}
