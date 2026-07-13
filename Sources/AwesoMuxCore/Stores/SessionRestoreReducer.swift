import Foundation
import UnicodeHygiene

struct SessionRestoreReducer: Sendable {
    struct RestoredSessionComponents: Sendable {
        var groups: [SessionGroup]
        var selectedSessionID: TerminalSession.ID?
        var recentlyClosed: [RecentlyClosedWorkspace]
        var pinnedSessionIDs: [TerminalSession.ID]
        var sanitizationSummary: SessionRestoreSanitizationSummary
    }

    // Use-time layout-depth cap. `TerminalSplit.maxDecodedSplitDepth` (the
    // decode-time bound) is deliberately kept above this so legal-depth layouts
    // decode and are collapsed here rather than thrown at decode — keep that
    // ordering if this value changes.
    static let maxRestoredLayoutDepth = 64

    static func restoredComponents(
        from snapshot: SessionSnapshot,
        now: Date = Date()
    ) -> RestoredSessionComponents {
        var seenSessionIDs = Set<TerminalSession.ID>()
        var seenSplitIDs = Set<TerminalSplit.ID>()
        var seenPaneIDs = Set<TerminalPane.ID>()
        var seenTerminalSessionIDs = Set<TerminalSessionID>()
        var sanitizationSummary = SessionRestoreSanitizationSummary()

        var restoredGroups: [SessionGroup] = []
        for group in snapshot.groups {
            // A confusable (mixed-script) persisted name is a *policy*
            // rejection, not an unusable value: quarantine the group under the
            // canonical default name so its sessions survive, and count it as
            // an adjustment — never a drop (INT-485).
            let restoredName = UnicodeHygiene.hasSuspiciousScriptMixing(group.name)
                ? SessionStoreText.canonicalDefaultGroupName
                : SessionStoreText.sanitizedGroupName(group.name)
            guard !restoredName.isEmpty else {
                sanitizationSummary.droppedGroups += 1
                continue
            }

            if restoredName != group.name {
                sanitizationSummary.groupNameAdjustments += 1
            }

            // Copy-mutate instead of re-init so fields this pass doesn't touch
            // (`remote`, and anything added to SessionGroup later) survive the
            // rebuild — a re-init with defaulted params silently dropped
            // `remote` on every relaunch (INT-767).
            var restoredGroup = group
            restoredGroup.name = restoredName
            restoredGroup.sessions = group.sessions.enumerated().map { offset, session in
                restoredSession(
                    from: session,
                    legacyExecutionPlan: group.remote
                        .map { .ssh(SSHExecution(target: $0)) }
                        ?? .local,
                    fallbackIndex: offset + 1,
                    seenSessionIDs: &seenSessionIDs,
                    seenSplitIDs: &seenSplitIDs,
                    seenPaneIDs: &seenPaneIDs,
                    seenTerminalSessionIDs: &seenTerminalSessionIDs,
                    sanitizationSummary: &sanitizationSummary
                )
            }
            restoredGroups.append(restoredGroup)
        }

        var mergedGroups: [SessionGroup] = []
        // Synthetic names must dodge EVERY restored name, not just the ones
        // merged so far — otherwise a renamed "name 2" swallows a legitimate
        // later group that was always called "name 2".
        var reservedNames = restoredGroups.map(\.name)
        for group in restoredGroups {
            if let existingIndex = mergedGroups.firstIndex(where: {
                $0.name.caseInsensitiveCompare(group.name) == .orderedSame
            }) {
                if mergedGroups[existingIndex].remote == group.remote {
                    sanitizationSummary.mergedGroups += 1
                    mergedGroups[existingIndex].sessions.append(contentsOf: group.sessions)
                } else {
                    // Never fold sessions across a local/remote (or cross-host)
                    // boundary: the absorbed sessions would inherit the winning
                    // group's transport, silently landing "remote" panes in a
                    // local shell or pointing local panes at an SSH host
                    // (ADR-0022). Keep the group, renamed — name uniqueness must
                    // hold because addSession(groupName:) routes by name.
                    var quarantined = group
                    quarantined.name = disambiguatedName(
                        for: group.name,
                        reserved: reservedNames
                    )
                    reservedNames.append(quarantined.name)
                    sanitizationSummary.groupNameAdjustments += 1
                    mergedGroups.append(quarantined)
                }
            } else {
                mergedGroups.append(group)
            }
        }

        var groups = mergedGroups
        reassignDuplicateGroupIDs(
            in: &groups,
            sanitizationSummary: &sanitizationSummary
        )

        let restoredSessionIDs = Set(groups.flatMap(\.sessions).map(\.id))

        // Sessions whose IDs get reassigned during sanitization intentionally
        // lose their pin: a duplicated-ID snapshot is already corrupt, and the
        // pin is disposable UI state, not worth chasing across a reassignment.
        var seenPinnedIDs = Set<TerminalSession.ID>()
        let restoredPinned = snapshot.pinnedSessionIDs.filter {
            restoredSessionIDs.contains($0) && seenPinnedIDs.insert($0).inserted
        }

        let restoredSelection: TerminalSession.ID?
        if let selectedSessionID = snapshot.selectedSessionID {
            if restoredSessionIDs.contains(selectedSessionID) {
                restoredSelection = selectedSessionID
            } else if restoredSessionIDs.isEmpty {
                restoredSelection = nil
            } else {
                sanitizationSummary.selectedSessionFallbacks += 1
                restoredSelection = nil
            }
        } else {
            restoredSelection = nil
        }

        let cutoff = now.addingTimeInterval(-RecentlyClosedWorkspaceReducer.recentlyClosedTTL)
        let prunedRecentlyClosed = Array(
            snapshot.recentlyClosed
                .filter { $0.closedAt >= cutoff }
                .prefix(RecentlyClosedWorkspaceReducer.maxRecentlyClosed)
        )

        return RestoredSessionComponents(
            groups: groups,
            selectedSessionID: restoredSelection ?? WorkspaceTreeReducer.firstSessionID(in: groups),
            recentlyClosed: prunedRecentlyClosed,
            pinnedSessionIDs: restoredPinned,
            sanitizationSummary: sanitizationSummary
        )
    }

    static func restoredSession(
        from session: TerminalSession,
        legacyExecutionPlan: PaneExecutionPlan = .local,
        fallbackIndex: Int,
        seenSessionIDs: inout Set<TerminalSession.ID>,
        seenSplitIDs: inout Set<TerminalSplit.ID>,
        seenPaneIDs: inout Set<TerminalPane.ID>,
        seenTerminalSessionIDs: inout Set<TerminalSessionID>,
        sanitizationSummary: inout SessionRestoreSanitizationSummary
    ) -> TerminalSession {
        let restoredSessionID: TerminalSession.ID
        if seenSessionIDs.insert(session.id).inserted {
            restoredSessionID = session.id
        } else {
            restoredSessionID = UUID()
            sanitizationSummary.idReassignments += 1
        }

        let activeExecutionState = restoredAgentExecutionState(
            session.activePane?.agentExecutionState ?? .idle
        )
        let activeAttentionReason = restoredAttentionReason(session.activePane?.attentionReason)
        let activeAgentKind = restoredAgentKind(
            session.activeAgentKind,
            executionState: activeExecutionState,
            attentionReason: activeAttentionReason
        )
        let sanitizedSessionTitle = SessionStoreText.sanitizedTitle(session.title)
        let fallbackSyntheticTitle = sanitizedSessionTitle.isEmpty
            ? SyntheticSessionTitle(agentKind: activeAgentKind, index: fallbackIndex)
            : session.syntheticTitle
        let fallbackTitle = fallbackSyntheticTitle?.localizedTitle()
            ?? SessionStoreText.restoredTitle(
                session.title,
                fallbackForAgent: activeAgentKind,
                index: fallbackIndex
            )
        let fallbackWorkingDirectory = WorkingDirectoryValidator.sanitizedRestoredDirectory(
            session.workingDirectory
        )

        guard layoutDepth(session.layout) <= maxRestoredLayoutDepth else {
            sanitizationSummary.collapsedLayouts += 1
            if fallbackTitle != session.title {
                sanitizationSummary.sessionTitleAdjustments += 1
            }
            if workingDirectoryWasRejected(
                original: session.workingDirectory,
                sanitized: fallbackWorkingDirectory
            ) {
                sanitizationSummary.sessionWorkingDirectoryAdjustments += 1
            }
            return TerminalSession(
                id: restoredSessionID,
                title: fallbackTitle,
                workingDirectory: fallbackWorkingDirectory,
                syntheticTitle: fallbackSyntheticTitle,
                isTitleUserEdited: session.isTitleUserEdited,
                notificationsMuted: session.notificationsMuted,
                agentKind: activeAgentKind,
                agentExecutionState: activeExecutionState,
                attentionReason: activeAttentionReason,
                executionPlan: session.activePane?.hasExplicitExecutionPlan == true
                    ? session.activePane?.executionPlan ?? legacyExecutionPlan
                    : legacyExecutionPlan
            )
        }

        let layoutResult = restoredLayout(
            from: session.layout,
            seenSplitIDs: &seenSplitIDs,
            seenPaneIDs: &seenPaneIDs,
            seenTerminalSessionIDs: &seenTerminalSessionIDs
        ) { pane in
            let paneWorkingDirectory = WorkingDirectoryValidator.sanitizedRestoredDirectory(
                pane.workingDirectory
            )
            if workingDirectoryWasRejected(
                original: pane.workingDirectory,
                sanitized: paneWorkingDirectory
            ) {
                sanitizationSummary.paneWorkingDirectoryAdjustments += 1
            }

            let executionState = restoredAgentExecutionState(pane.agentExecutionState)
            let attentionReason = restoredAttentionReason(pane.attentionReason)
            let agentKind = restoredAgentKind(
                pane.agentKind,
                executionState: executionState,
                attentionReason: attentionReason
            )
            let paneTitle = SessionStoreText.restoredTitle(
                pane.title,
                fallbackForAgent: agentKind,
                index: fallbackIndex
            )
            if paneTitle != pane.title {
                sanitizationSummary.paneTitleAdjustments += 1
            }

            // Preserve only still-live restored agent identity. A prompt-ready
            // `.waiting` pane or preserved blocking prompt keeps its provider
            // chrome; stale idle metadata falls back to shell.
            let executionPlan =
                pane.hasExplicitExecutionPlan
                ? pane.executionPlan
                : legacyExecutionPlan
            return TerminalPane(
                id: pane.id,
                terminalSessionID: pane.terminalSessionID,
                terminalBackendMetadata: pane.terminalBackendMetadata,
                title: paneTitle,
                // Drop the freeze if the pinned title sanitized away to a
                // synthetic fallback — a name the user never chose must not stay
                // pinned against the live OSC title (INT-283 / QA H1).
                isTitleUserEdited: pane.isTitleUserEdited
                    && !SessionStoreText.titleSanitizesToFallback(pane.title),
                workingDirectory: paneWorkingDirectory,
                color: pane.color,
                agentKind: agentKind,
                agentExecutionState: executionState,
                attentionReason: attentionReason,
                executionPlan: executionPlan
            )
        }
        let layout = layoutResult.layout
        sanitizationSummary.idReassignments += layoutResult.idReassignments

        if case .split = session.layout, fallbackTitle != session.title {
            sanitizationSummary.sessionTitleAdjustments += 1
        }

        // A layout with no terminal pane (doc-only root) is invalid. Drop it
        // rather than trapping — `firstPane == nil` means there is nothing to
        // restore, and a preconditionFailure here would be uncatchable and
        // crash-loop the app (C1). Return a fresh default session instead so
        // the slot is usable rather than lost entirely.
        let resolvedActivePane: TerminalPane
        if let activePane = layout.pane(id: session.activePaneID) {
            resolvedActivePane = activePane
        } else if let firstPane = layout.firstPane {
            sanitizationSummary.activePaneFallbacks += 1
            resolvedActivePane = firstPane
        } else {
            sanitizationSummary.collapsedLayouts += 1
            return TerminalSession(
                id: restoredSessionID,
                title: fallbackTitle,
                workingDirectory: fallbackWorkingDirectory,
                syntheticTitle: fallbackSyntheticTitle,
                isTitleUserEdited: session.isTitleUserEdited,
                notificationsMuted: session.notificationsMuted,
                executionPlan: session.activePane?.hasExplicitExecutionPlan == true
                    ? session.activePane?.executionPlan ?? legacyExecutionPlan
                    : legacyExecutionPlan
            )
        }

        // Lone-pane carve-out parity with `syncSessionChromeToActivePane`: a
        // pinned lone pane owns the workspace title, so a snapshot whose
        // persisted session title drifted from the pin must not restore stale
        // chrome (it would otherwise sit wrong until the first OSC tick
        // re-syncs). A user-renamed workspace still wins.
        let restoredTitle: String
        if !session.isTitleUserEdited,
           !layout.hasMultiplePanes,
           resolvedActivePane.isTitleUserEdited {
            restoredTitle = resolvedActivePane.title
        } else {
            restoredTitle = fallbackTitle
        }

        // The rebuilt panes already carry their preserved kind + restored
        // execution state, so pass no session-level agent params — that would
        // fold over (and clobber) the active pane's restored state (INT-504 R5).
        return TerminalSession(
            id: restoredSessionID,
            title: restoredTitle,
            workingDirectory: resolvedActivePane.workingDirectory,
            syntheticTitle: fallbackSyntheticTitle,
            isTitleUserEdited: session.isTitleUserEdited,
            notificationsMuted: session.notificationsMuted,
            layout: layout,
            activePaneID: resolvedActivePane.id
        )
    }

    /// Exhaustive so a new `AgentExecutionState` case forces a decision here
    /// instead of silently falling into a default. Policy per case:
    /// - `.waiting`: round-trips. It's the hook side-channel's live
    ///   permission-prompt signal (see `restoredAttentionReason` above) and is
    ///   the one state that genuinely survives a restart unresolved.
    /// - `.running` / `.thinking` / `.output`: clamp to `.idle`. These only
    ///   mean something while the process that produced them is alive; a
    ///   restored session has no live process, so keeping them would badge a
    ///   session as busy when nothing is actually running.
    /// - `.done` / `.error`: clamp to `.idle`. Both are terminal-but-quiet
    ///   states rendered as one-shot completion/error indicators tied to the
    ///   run that produced them; restore has no way to re-attach that run, so
    ///   preserving them would show a stale badge with no way to resolve it.
    /// - `.idle`: round-trips (no-op).
    static func restoredAgentExecutionState(
        _ state: AgentExecutionState
    ) -> AgentExecutionState {
        switch state {
        case .waiting:
            return .waiting
        case .idle, .running, .thinking, .output, .done, .error:
            return .idle
        }
    }

    static func restoredAgentKind(
        _ kind: AgentKind,
        executionState: AgentExecutionState,
        attentionReason: AttentionReason?
    ) -> AgentKind {
        // Callers pass already-restored state/reason: stale execution states have
        // been clamped to idle and non-live attention reasons have been dropped.
        guard kind != .shell else { return .shell }

        if executionState == .waiting || attentionReason != nil {
            return kind
        }

        return .shell
    }

    /// R5 relaunch policy: a live permission prompt / user-input-required
    /// survives quit and restores badged, because the agent is genuinely still
    /// blocked waiting on the user. Every other reason — a bell, a desktop
    /// notification, a process error, or an `.unknown` — is treated as stale
    /// runtime noise and cleared on restore.
    static func restoredAttentionReason(
        _ reason: AttentionReason?
    ) -> AttentionReason? {
        switch reason {
        case .userInputRequired, .permissionPrompt:
            return reason
        case .bell, .desktopNotification, .processError, .unknown, .none:
            return nil
        }
    }

    static func layoutDepth(_ layout: TerminalPaneLayout) -> Int {
        switch layout {
        case .pane:
            return 1
        case let .split(split):
            return 1 + max(layoutDepth(split.first), layoutDepth(split.second))
        case .documentGroup:
            return 1
        }
    }

    static func workingDirectoryWasRejected(original: String, sanitized: String) -> Bool {
        sanitized == "~" && original != "~"
    }

    /// Smallest-numbered `"name N"` (N ≥ 2) colliding with no reserved name,
    /// trimming the base so the result respects the group-name cap.
    static func disambiguatedName(
        for baseName: String,
        reserved reservedNames: [String]
    ) -> String {
        var counter = 2
        while true {
            let suffix = " \(counter)"
            let trimmedBase = String(
                baseName.prefix(SessionStoreText.maxGroupNameLength - suffix.count)
            )
            let candidate = trimmedBase + suffix
            let collides = reservedNames.contains {
                $0.caseInsensitiveCompare(candidate) == .orderedSame
            }
            if !collides {
                return candidate
            }
            counter += 1
        }
    }

    static func reassignDuplicateGroupIDs(
        in groups: inout [SessionGroup],
        sanitizationSummary: inout SessionRestoreSanitizationSummary
    ) {
        var seenGroupIDs = Set<SessionGroup.ID>()
        for index in groups.indices {
            let group = groups[index]
            guard !seenGroupIDs.insert(group.id).inserted else {
                continue
            }

            var replacementID = UUID()
            while seenGroupIDs.contains(replacementID) {
                replacementID = UUID()
            }
            seenGroupIDs.insert(replacementID)
            // Mutate only the identity field so newly persisted group fields
            // cannot be silently reset during duplicate-ID repair.
            groups[index].reassignIDForRestore(replacementID)
            sanitizationSummary.idReassignments += 1
        }
    }

    static func restoredLayout(
        from layout: TerminalPaneLayout,
        seenSplitIDs: inout Set<TerminalSplit.ID>,
        seenPaneIDs: inout Set<TerminalPane.ID>,
        seenTerminalSessionIDs: inout Set<TerminalSessionID>,
        transformPane: (TerminalPane) -> TerminalPane
    ) -> (layout: TerminalPaneLayout, idReassignments: Int) {
        switch layout {
        case let .pane(pane):
            var restoredPane = transformPane(pane)
            var idReassignments = 0
            if !seenPaneIDs.insert(restoredPane.id).inserted {
                // Reassign only the id; carry the transformed agent state through.
                // Rebuilding with id/title/cwd alone silently downgraded an agent
                // pane to a bare .shell/.idle — the same class of loss the rest of
                // INT-504 fixed (OpenCode review on PR #231).
                restoredPane = TerminalPane(
                    id: UUID(),
                    terminalSessionID: restoredPane.terminalSessionID,
                    terminalBackendMetadata: restoredPane.terminalBackendMetadata,
                    title: restoredPane.title,
                    isTitleUserEdited: restoredPane.isTitleUserEdited,
                    workingDirectory: restoredPane.workingDirectory,
                    color: restoredPane.color,
                    agentKind: restoredPane.agentKind,
                    agentExecutionState: restoredPane.agentExecutionState,
                    attentionReason: restoredPane.attentionReason,
                    unreadNotificationCount: restoredPane.unreadNotificationCount,
                    executionPlan: restoredPane.executionPlan
                )
                seenPaneIDs.insert(restoredPane.id)
                idReassignments += 1
            }
            if !seenTerminalSessionIDs.insert(restoredPane.terminalSessionID).inserted {
                let terminalSessionID = generateUniqueTerminalSessionID(
                    avoiding: &seenTerminalSessionIDs
                )
                restoredPane = TerminalPane(
                    id: restoredPane.id,
                    terminalSessionID: terminalSessionID,
                    terminalBackendMetadata: .empty,
                    title: restoredPane.title,
                    isTitleUserEdited: restoredPane.isTitleUserEdited,
                    workingDirectory: restoredPane.workingDirectory,
                    color: restoredPane.color,
                    agentKind: restoredPane.agentKind,
                    agentExecutionState: restoredPane.agentExecutionState,
                    attentionReason: restoredPane.attentionReason,
                    unreadNotificationCount: restoredPane.unreadNotificationCount,
                    executionPlan: restoredPane.executionPlan
                )
                idReassignments += 1
            }
            return (.pane(restoredPane), idReassignments)

        case .split(let split):
            var idReassignments = 0
            let restoredID: TerminalSplit.ID
            if seenSplitIDs.insert(split.id).inserted {
                restoredID = split.id
            } else {
                restoredID = UUID()
                idReassignments += 1
            }
            let first = restoredLayout(
                from: split.first,
                seenSplitIDs: &seenSplitIDs,
                seenPaneIDs: &seenPaneIDs,
                seenTerminalSessionIDs: &seenTerminalSessionIDs,
                transformPane: transformPane
            )
            let second = restoredLayout(
                from: split.second,
                seenSplitIDs: &seenSplitIDs,
                seenPaneIDs: &seenPaneIDs,
                seenTerminalSessionIDs: &seenTerminalSessionIDs,
                transformPane: transformPane
            )
            idReassignments += first.idReassignments + second.idReassignments
            return (
                .split(
                    TerminalSplit(
                        id: restoredID,
                        orientation: split.orientation,
                        first: first.layout,
                        second: second.layout,
                        firstFraction: split.firstFraction
                    )
                ),
                idReassignments
            )

        case let .documentGroup(group):
            var restoredGroup = group
            var idReassignments = 0
            // Group and tab ids share the pane-id dedup pool, matching how the
            // legacy `.document` leaf id was checked. A duplicated tab remints
            // with its file identity AND terminal association carried through —
            // a dangling association is handled at use time (fail closed), so
            // no reassignment map is needed here.
            if !seenPaneIDs.insert(restoredGroup.id).inserted {
                restoredGroup = DocumentGroup(
                    id: UUID(),
                    tabs: restoredGroup.tabs,
                    selectedTabID: restoredGroup.selectedTabID
                )
                seenPaneIDs.insert(restoredGroup.id)
                idReassignments += 1
            }
            for index in restoredGroup.tabs.indices {
                let tab = restoredGroup.tabs[index]
                guard !seenPaneIDs.insert(tab.id).inserted else { continue }
                let remintedTab = DocumentPane(
                    id: UUID(),
                    fileURL: tab.fileURL,
                    title: tab.title,
                    associatedTerminalPaneID: tab.associatedTerminalPaneID,
                    remoteResourceIdentity: tab.remoteResourceIdentity
                )
                seenPaneIDs.insert(remintedTab.id)
                if restoredGroup.selectedTabID == tab.id {
                    restoredGroup.selectedTabID = remintedTab.id
                }
                restoredGroup.tabs[index] = remintedTab
                idReassignments += 1
            }
            return (.documentGroup(restoredGroup), idReassignments)
        }
    }

    static func generateUniqueTerminalSessionID(
        avoiding seenTerminalSessionIDs: inout Set<TerminalSessionID>,
        generate: () -> TerminalSessionID = TerminalSessionID.generate
    ) -> TerminalSessionID {
        var candidate = generate()
        while !seenTerminalSessionIDs.insert(candidate).inserted {
            candidate = generate()
        }
        return candidate
    }
}
