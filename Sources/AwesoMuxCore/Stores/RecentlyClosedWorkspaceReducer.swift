import Foundation

struct RecentlyClosedWorkspaceReducer: Sendable {
    static let maxRecentlyClosed: Int = 20
    // 24h, not longer: closed-workspace paths are a disclosure surface
    // (Time Machine, Spotlight, sysdiagnose). See ADR 0015.
    static let recentlyClosedTTL: TimeInterval = 24 * 60 * 60

    struct CaptureDecision: Sendable {
        var entry: RecentlyClosedWorkspace
        var shouldPersist: Bool
    }

    static func captureDecision(
        session: TerminalSession,
        group: SessionGroup,
        indexInGroup: Int,
        now: Date
    ) -> CaptureDecision {
        let entry = RecentlyClosedWorkspace(
            sessionID: session.id,
            title: session.syntheticTitle?.canonicalTitle ?? session.title,
            syntheticTitle: session.syntheticTitle,
            isTitleUserEdited: session.isTitleUserEdited,
            agentKind: session.activeAgentKind,
            layout: session.layout,
            activePaneID: session.activePaneID,
            groupID: group.id,
            groupName: group.name,
            groupRemote: group.remote,
            indexInGroup: indexInGroup,
            closedAt: now
        )
        return CaptureDecision(entry: entry, shouldPersist: isWorthRecording(session))
    }

    static func recordPersisted(
        _ entry: RecentlyClosedWorkspace,
        recentlyClosed: inout [RecentlyClosedWorkspace],
        lastClosedTransient: inout RecentlyClosedWorkspace?,
        now: Date
    ) {
        prune(
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &lastClosedTransient,
            now: now
        )
        recentlyClosed.insert(entry, at: 0)
        if recentlyClosed.count > maxRecentlyClosed {
            recentlyClosed.removeLast(recentlyClosed.count - maxRecentlyClosed)
        }
    }

    static func prune(
        recentlyClosed: inout [RecentlyClosedWorkspace],
        lastClosedTransient: inout RecentlyClosedWorkspace?,
        now: Date
    ) {
        let cutoff = now.addingTimeInterval(-recentlyClosedTTL)
        recentlyClosed.removeAll { $0.closedAt < cutoff }
        if let transient = lastClosedTransient, transient.closedAt < cutoff {
            lastClosedTransient = nil
        }
    }

    @discardableResult
    static func reopenMostRecentlyClosed(
        in groups: inout [SessionGroup],
        recentlyClosed: inout [RecentlyClosedWorkspace],
        lastClosedTransient: inout RecentlyClosedWorkspace?,
        now: Date
    ) -> TerminalSession.ID? {
        prune(
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &lastClosedTransient,
            now: now
        )
        let entry: RecentlyClosedWorkspace
        switch (lastClosedTransient, recentlyClosed.first) {
        case (nil, nil):
            return nil
        case (.some(let transient), nil):
            entry = transient
        case (nil, .some(let persisted)):
            entry = persisted
        case (.some(let transient), .some(let persisted)):
            entry = transient.closedAt >= persisted.closedAt ? transient : persisted
        }
        // Consume the chosen entry from both tiers so a second Cmd-Shift-T
        // cannot resurrect a stale twin, then rebuild it.
        _ = drain(
            entry: entry,
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &lastClosedTransient
        )
        return insertReopened(entry: entry, into: &groups)
    }

    /// Reopen a specific recently-closed workspace chosen by the user (e.g. the
    /// Dock "Recent Workspaces" submenu). The passed `entry` carries the full
    /// snapshot used to rebuild the workspace; the row it drains is located by
    /// identity fields `(sessionID, closedAt)` (see `drain`). Returns nil when
    /// the entry is no longer present — already reopened, or TTL-pruned between
    /// menu build and selection.
    @discardableResult
    static func reopen(
        entry: RecentlyClosedWorkspace,
        in groups: inout [SessionGroup],
        recentlyClosed: inout [RecentlyClosedWorkspace],
        lastClosedTransient: inout RecentlyClosedWorkspace?,
        now: Date
    ) -> TerminalSession.ID? {
        prune(
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &lastClosedTransient,
            now: now
        )
        guard
            drain(
                entry: entry,
                recentlyClosed: &recentlyClosed,
                lastClosedTransient: &lastClosedTransient
            )
        else {
            return nil
        }
        return insertReopened(entry: entry, into: &groups)
    }

    /// Remove `entry` from both reopen tiers by exact equality. Returns whether
    /// anything was removed, so the targeted reopen can detect an entry that
    /// vanished between menu build and selection.
    @discardableResult
    private static func drain(
        entry: RecentlyClosedWorkspace,
        recentlyClosed: inout [RecentlyClosedWorkspace],
        lastClosedTransient: inout RecentlyClosedWorkspace?
    ) -> Bool {
        // Match on identity fields (sessionID + closedAt), not full-value `==`.
        // RecentlyClosedWorkspace equality walks TerminalPane ==, which excludes
        // per-pane backend daemon identity, so full-value matching can't tell two
        // rows apart by daemon and could drain the wrong one. sessionID is unique
        // per close (each close records the session's UUID; reopen mints new
        // ones), so (sessionID, closedAt) picks exactly the chosen row in all
        // real data. Removing a single row also keeps a twin's daemon reachable
        // (DaemonGCPlan keys on terminalSessionID).
        //
        // ponytail: a corrupted snapshot with two rows sharing BOTH sessionID and
        // closedAt but pointing at different daemons would still be ambiguous.
        // That needs a stable per-entry id + a Codable migration — add it if such
        // corruption ever shows up; unreachable from normal closes today.
        var removed = false
        if let transient = lastClosedTransient, Self.isSameEntry(transient, entry) {
            lastClosedTransient = nil
            removed = true
        }
        if let index = recentlyClosed.firstIndex(where: { Self.isSameEntry($0, entry) }) {
            recentlyClosed.remove(at: index)
            removed = true
        }
        return removed
    }

    private static func isSameEntry(
        _ lhs: RecentlyClosedWorkspace,
        _ rhs: RecentlyClosedWorkspace
    ) -> Bool {
        lhs.sessionID == rhs.sessionID && lhs.closedAt == rhs.closedAt
    }

    /// Rebuild a closed workspace from its snapshot and insert it, minting fresh
    /// identities only where a stored id collides with a live pane/daemon.
    /// Shared by head reopen and targeted reopen; callers drain the entry from
    /// the reopen tiers first. A layout deeper than the restore cap is dropped
    /// (returns nil); the caller has already consumed the entry.
    private static func insertReopened(
        entry: RecentlyClosedWorkspace,
        into groups: inout [SessionGroup]
    ) -> TerminalSession.ID? {
        guard
            SessionRestoreReducer.layoutDepth(entry.layout)
                <= SessionRestoreReducer.maxRestoredLayoutDepth
        else {
            return nil
        }

        // When the closed workspace's original group is gone, recreate it (in
        // both empty and non-empty trees) so the workspace comes home to its
        // named group rather than being dumped into whichever group happens to
        // be first. The new group is appended at index == groups.count.
        let liveGroupIndex = groups.firstIndex(where: { $0.id == entry.groupID })
        let groupIndex = liveGroupIndex ?? groups.count
        let destinationCount = liveGroupIndex.map { groups[$0].sessions.count } ?? 0
        let insertionIndex =
            liveGroupIndex != nil
            ? max(0, min(entry.indexInGroup, destinationCount))
            : destinationCount

        var paneIDRemap: [TerminalPane.ID: TerminalPane.ID] = [:]
        // Seed both collision sets with every identity already live in the
        // window. The reopened panes keep their own `terminalSessionID` AND their
        // own `pane.id` so they reattach to the still-running daemon and keep
        // receiving its agent events (INT-578) — the agent runtime event file is
        // keyed on `pane.id` (AgentRuntimeEnvironment), so reminting it would
        // reattach the terminal yet silently sever attention/unread/rename
        // events. A stored id that duplicates a LIVE pane's is reassigned
        // instead, so a corrupted-snapshot twin can't alias a live daemon or its
        // event file (mirrors SessionRestoreReducer's restore path).
        var seenTerminalSessionIDs = Set<TerminalSessionID>()
        var seenPaneIDs = Set<TerminalPane.ID>()
        for group in groups {
            for session in group.sessions {
                session.layout.forEachPane {
                    seenTerminalSessionIDs.insert($0.terminalSessionID)
                    seenPaneIDs.insert($0.id)
                }
            }
        }
        let restoredLayout = remappingDocumentTabAssociations(
            in: reidentifiedLayout(
                entry.layout,
                indexHint: insertionIndex + 1,
                legacyExecutionPlan: entry.groupRemote.map {
                    PaneExecutionPlan.ssh(SSHExecution(target: $0))
                } ?? .local,
                paneIDRemap: &paneIDRemap,
                seenTerminalSessionIDs: &seenTerminalSessionIDs,
                seenPaneIDs: &seenPaneIDs
            ),
            paneIDRemap: paneIDRemap
        )
        // Prefer the remapped original active pane; fall back to the first
        // terminal pane. If the restored layout has no terminal pane at all
        // (a doc-only entry that should never have been persisted), bail
        // rather than trapping in `firstPaneID` (C1).
        guard
            let restoredActivePaneID = paneIDRemap[entry.activePaneID]
                ?? restoredLayout.firstPane?.id
        else {
            return nil
        }
        // Recently closed entries come from live sessions we already trusted;
        // avoid synchronous cwd validation on reopen so remote or unmounted
        // paths are preserved for the terminal to handle.
        let activeCwd =
            restoredLayout.pane(id: restoredActivePaneID)?.workingDirectory
            ?? restoredLayout.firstPane?.workingDirectory
            ?? "~"
        let fallbackTitle = SessionStoreText.restoredTitle(
            entry.title,
            fallbackForAgent: entry.agentKind,
            index: insertionIndex + 1
        )
        let restoredSyntheticTitle = entry.syntheticTitle.map { candidate in
            let hasCollision = groups.contains { group in
                group.sessions.contains { session in
                    session.syntheticTitle == candidate
                        || session.title == candidate.canonicalTitle
                        || session.title == candidate.localizedTitle()
                }
            }
            return hasCollision
                ? WorkspaceTreeReducer.nextSyntheticSessionTitle(
                    in: groups, for: candidate.agentKind)
                : candidate
        }

        let restored = TerminalSession(
            title: restoredSyntheticTitle?.canonicalTitle ?? fallbackTitle,
            workingDirectory: activeCwd,
            syntheticTitle: restoredSyntheticTitle,
            isTitleUserEdited: entry.isTitleUserEdited,
            agentKind: entry.agentKind,
            // No session-level agentState: `reidentifiedLayout` already set each
            // pane's execution state per policy (.waiting round-trips with kept
            // daemon identity, everything else .idle); a session-level value
            // would fold over and clobber the active pane's (INT-504 R5).
            layout: restoredLayout,
            activePaneID: restoredActivePaneID
        )

        if groupIndex == groups.count {
            // We only reach the append when no live group matched entry.groupID,
            // so a collision here is currently unreachable. Keep the dedup as
            // cheap insurance against a future refactor: a duplicate group ID
            // desyncs SessionStoreIndex lookup state, so mint a fresh one rather
            // than trust the stored ID (mirrors the restore path's dedup).
            let liveGroupIDs = Set(groups.map(\.id))
            let groupID = liveGroupIDs.contains(entry.groupID) ? UUID() : entry.groupID
            // A live group with the same NAME (user deleted the group, then
            // hand-created a namesake) gets the restore path's disambiguation
            // ("staging 2") rather than a twin: folding in by name would hand
            // the session the namesake's remote — silently re-local-izing a
            // remote session, the INT-773 bug through the side door — and a
            // duplicate name breaks name-keyed session routing (`addSession`
            // and `insertSession` match groups by lookup key).
            let lookupName = SessionStoreText.groupLookupKey(entry.groupName)
            let groupName =
                WorkspaceTreeReducer.containsGroup(in: groups, named: lookupName)
                ? SessionRestoreReducer.disambiguatedName(
                    for: lookupName,
                    reserved: groups.map(\.name)
                )
                : lookupName
            groups.append(
                SessionGroup(
                    id: groupID,
                    name: groupName,
                    // Carry the SSH target captured at close time so the last
                    // workspace of a deleted remote group reopens REMOTE, not
                    // silently local (INT-773). Only this recreate path reads it —
                    // a matched LIVE group is authoritative over the stale capture,
                    // which also makes reopen ORDER decide the target when a group
                    // was retargeted between closes: the first reopened entry's
                    // capture recreates the group, later entries fold into it and
                    // their (older or newer) captures are deliberately discarded.
                    remote: entry.groupRemote,
                    sessions: []
                ))
        }
        groups[groupIndex].sessions.insert(restored, at: insertionIndex)
        return restored.id
    }

    static func isWorthRecording(_ session: TerminalSession) -> Bool {
        if session.activeAgentKind != .shell {
            return true
        }
        if session.isTitleUserEdited {
            return true
        }
        if session.unreadNotificationCount > 0 {
            return true
        }
        if session.layout.hasMultiplePanes {
            return true
        }
        if hasMeaningfulWorkingDirectory(session.workingDirectory) {
            return true
        }
        return false
    }

    static func hasMeaningfulWorkingDirectory(_ cwd: String) -> Bool {
        let trimmed = cwd.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "~" {
            return false
        }
        // Canonical home: stored cwds are canonicalized at ingest (INT-498), so
        // a raw NSHomeDirectory() compare would misclassify a home-directory
        // session as meaningful under a symlinked home.
        if trimmed == WorkingDirectoryValidator.canonicalHomeDirectory {
            return false
        }
        return true
    }

    static func reidentifiedLayout(
        _ layout: TerminalPaneLayout,
        indexHint: Int,
        legacyExecutionPlan: PaneExecutionPlan = .local,
        paneIDRemap: inout [TerminalPane.ID: TerminalPane.ID],
        seenTerminalSessionIDs: inout Set<TerminalSessionID>,
        seenPaneIDs: inout Set<TerminalPane.ID>
    ) -> TerminalPaneLayout {
        switch layout {
        case .pane(let pane):
            // Keep the pane's own id so its agent runtime event file (keyed on
            // pane.id) reattaches; remint only if it collides with a live pane.
            let newID: TerminalPane.ID
            let preservedPaneID: Bool
            if seenPaneIDs.insert(pane.id).inserted {
                newID = pane.id
                preservedPaneID = true
            } else {
                var fresh = UUID()
                while !seenPaneIDs.insert(fresh).inserted { fresh = UUID() }
                newID = fresh
                preservedPaneID = false
            }
            paneIDRemap[pane.id] = newID
            let sanitisedTitle = SessionStoreText.restoredTitle(
                pane.title,
                fallbackForAgent: pane.agentKind,
                index: indexHint
            )
            // Keep this pane's daemon identity so reopen reattaches to the
            // still-running daemon (INT-578). Daemon identity is COUPLED to the
            // pane id: the daemon's inner agent is bound to the ORIGINAL pane.id
            // (its baked-in AWESOMUX_PANE_ID / event file), so it can only be
            // reattached if we kept that pane.id. If the pane.id had to be
            // reassigned — or the daemon id itself collides with a live pane —
            // reattaching would route the agent's events to whichever pane owns
            // the old id, so start a fresh daemon instead and drop the metadata
            // (mirrors SessionRestoreReducer's independent dedup, with the extra
            // pane-id coupling the agent event plane requires).
            let terminalSessionID: TerminalSessionID
            let terminalBackendMetadata: TerminalBackendMetadata
            let preservedDaemonIdentity: Bool
            if preservedPaneID,
                seenTerminalSessionIDs.insert(pane.terminalSessionID).inserted
            {
                terminalSessionID = pane.terminalSessionID
                terminalBackendMetadata = pane.terminalBackendMetadata
                preservedDaemonIdentity = true
            } else {
                terminalSessionID = SessionRestoreReducer.generateUniqueTerminalSessionID(
                    avoiding: &seenTerminalSessionIDs
                )
                terminalBackendMetadata = .empty
                preservedDaemonIdentity = false
            }
            // Preserve each pane's own kind so reopening a split workspace
            // doesn't downgrade a sibling agent pane to a bare shell (INT-504).
            // Execution state follows launch restore's policy
            // (`restoredAgentExecutionState`: `.waiting` round-trips, everything
            // else clamps to `.idle`) — but only when the daemon identity was
            // kept, because `.waiting` only survives when the reopened pane can
            // reattach to the still-blocked agent (INT-578). A fresh daemon has
            // no waiting agent, so it comes back `.idle`. Attention/unread are
            // still dropped, like restore.
            return .pane(
                TerminalPane(
                    id: newID,
                    terminalSessionID: terminalSessionID,
                    terminalBackendMetadata: terminalBackendMetadata,
                    title: sanitisedTitle,
                    // Drop the freeze if the pinned title sanitized away to a
                    // synthetic fallback (INT-283 / QA H1) — mirrors restore.
                    isTitleUserEdited: pane.isTitleUserEdited
                        && !SessionStoreText.titleSanitizesToFallback(pane.title),
                    workingDirectory: pane.workingDirectory,
                    // Keep the pane's name-plate tint — it's durable user intent
                    // (red = prod, etc.), and restore preserves it, so reopen must
                    // too rather than coming back colourless (QA).
                    color: pane.color,
                    agentKind: pane.agentKind,
                    agentExecutionState: preservedDaemonIdentity
                        ? SessionRestoreReducer.restoredAgentExecutionState(
                            pane.agentExecutionState)
                        : .idle,
                    executionPlan: pane.hasExplicitExecutionPlan
                        ? pane.executionPlan
                        : legacyExecutionPlan
                ))
        case .split(let split):
            let first = reidentifiedLayout(
                split.first,
                indexHint: indexHint,
                legacyExecutionPlan: legacyExecutionPlan,
                paneIDRemap: &paneIDRemap,
                seenTerminalSessionIDs: &seenTerminalSessionIDs,
                seenPaneIDs: &seenPaneIDs
            )
            let second = reidentifiedLayout(
                split.second,
                indexHint: indexHint,
                legacyExecutionPlan: legacyExecutionPlan,
                paneIDRemap: &paneIDRemap,
                seenTerminalSessionIDs: &seenTerminalSessionIDs,
                seenPaneIDs: &seenPaneIDs
            )
            return .split(
                TerminalSplit(
                    id: UUID(),
                    orientation: split.orientation,
                    first: first,
                    second: second,
                    firstFraction: split.firstFraction
                ))
        case .documentGroup(let group):
            // Remint the group's and every tab's own ID so a reopened workspace
            // doesn't alias the original. Tab IDs are NOT TerminalPane.IDs, so
            // they stay outside paneIDRemap/seenPaneIDs (no daemon/agent
            // identity). Each tab's terminal association still carries the OLD
            // pane id here — the caller remaps it through the completed
            // `paneIDRemap` after the whole walk, because an association may
            // point at a pane later in tree order than this group.
            var remintedTabs: [DocumentPane] = []
            var selectedTabID: DocumentPane.ID?
            for tab in group.tabs {
                let reminted = DocumentPane(
                    id: UUID(),
                    fileURL: tab.fileURL,
                    title: tab.title,
                    associatedTerminalPaneID: tab.associatedTerminalPaneID,
                    remoteSnapshotOrigin: tab.remoteSnapshotOrigin
                )
                if group.selectedTabID == tab.id {
                    selectedTabID = reminted.id
                }
                remintedTabs.append(reminted)
            }
            return .documentGroup(
                DocumentGroup(
                    id: UUID(),
                    tabs: remintedTabs,
                    selectedTabID: selectedTabID ?? remintedTabs[0].id
                ))
        }
    }

    /// Remaps every document tab's terminal association through the completed
    /// pane-id remap. An association whose pane is not part of the reopened
    /// workspace clears to nil — send fails closed rather than pointing at a
    /// pane in the still-open original (INT-748).
    static func remappingDocumentTabAssociations(
        in layout: TerminalPaneLayout,
        paneIDRemap: [TerminalPane.ID: TerminalPane.ID]
    ) -> TerminalPaneLayout {
        guard var group = layout.firstDocumentGroup else {
            return layout
        }
        group.tabs = group.tabs.map { tab in
            var tab = tab
            tab.associatedTerminalPaneID = tab.associatedTerminalPaneID
                .flatMap { paneIDRemap[$0] }
            return tab
        }
        return layout.replacingDocumentGroup(id: group.id, with: group) ?? layout
    }

}
