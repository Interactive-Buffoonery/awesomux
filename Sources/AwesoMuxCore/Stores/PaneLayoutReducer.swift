import AwesoMuxBridgeProtocol
import Foundation

struct PaneLayoutReducer: Sendable {
    struct RecycleResult: Sendable {
        var session: TerminalSession
        var discardedPaneID: TerminalPane.ID
    }

    /// Seeds a fresh pane from the live title, never a pinned custom title.
    private static func freshPaneSeedTitle(from source: TerminalPane) -> String {
        if let live = source.liveTerminalTitle, !live.isEmpty {
            return live
        }
        guard source.isTitleUserEdited else {
            return source.title
        }
        let basename = (source.workingDirectory as NSString).lastPathComponent
        return basename.isEmpty ? source.workingDirectory : basename
    }

    static func splitActivePane(
        in session: TerminalSession,
        orientation: TerminalSplitOrientation,
        now: Date
    ) -> (session: TerminalSession, newPaneID: TerminalPane.ID)? {
        var session = session
        guard let activePane = session.activePane else {
            return nil
        }

        let newPane = TerminalPane(
            title: Self.freshPaneSeedTitle(from: activePane),
            workingDirectory: activePane.workingDirectory,
            lastAgentStateChangeAt: now,
            executionPlan: activePane.executionPlan
        )

        // `.done` outranks `.idle`, so clear stale completion before adding a
        // fresh shell sibling. Live running/error states stay visible.
        var splitOffPane = activePane
        if splitOffPane.agentExecutionState == .done {
            splitOffPane.agentExecutionState = .idle
            splitOffPane.lastAgentStateChangeAt = now
        }

        let replacement = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: orientation,
                first: .pane(splitOffPane),
                second: .pane(newPane)
            )
        )

        guard
            let layout = session.layout.replacingPane(
                id: activePane.id,
                with: replacement
            )
        else {
            return nil
        }

        session.layout = layout
        session.activePaneID = newPane.id
        // Re-sync chrome for the transition out of the lone-pane carve-out: a
        // pinned lone pane owns the workspace title, but the moment it gains a
        // sibling F6 applies and the title must revert to the live-derived
        // name. The new pane is active and unfrozen, so sync adopts its seed.
        syncSessionChromeToActivePane(&session)
        return (session, newPane.id)
    }

    /// Opens or selects a document tab without moving terminal focus.
    /// Existing live associations are preserved; dead ones may heal to the
    /// incoming pane so send/stage does not stay permanently disabled.
    static func openDocumentTab(
        fileURL: URL,
        associatedTerminalPaneID: TerminalPane.ID?,
        remoteResourceIdentity: ResourceIdentity? = nil,
        in session: TerminalSession,
        now: Date,
        selectingNewTab: Bool = true
    ) -> (session: TerminalSession, newTabID: DocumentPane.ID)? {
        let normalizedURL = fileURL.standardizedFileURL
        let liveIncomingAssociation = associatedTerminalPaneID.flatMap {
            session.layout.pane(id: $0)?.id
        }
        let title = documentTabTitle(
            fileURL: normalizedURL,
            remoteResourceIdentity: remoteResourceIdentity
        )
        var session = session

        if let group = session.layout.firstDocumentGroup {
            var group = group
            let matchingTab: DocumentPane?
            if let remoteResourceIdentity {
                matchingTab = group.tab(forRemoteResource: remoteResourceIdentity)
            } else {
                matchingTab =
                    group.tab(forNormalizedURL: normalizedURL)
                    ?? group.tabs.first(where: {
                        $0.fileURL.standardizedFileURL == normalizedURL
                            && $0.remoteResourceIdentity != nil
                    })
            }
            if var existing = matchingTab {
                var changed = false
                let storedAssociationIsDead =
                    existing.associatedTerminalPaneID
                    .map { session.layout.pane(id: $0) == nil } ?? true
                if storedAssociationIsDead,
                    let incoming = liveIncomingAssociation,
                    incoming != existing.associatedTerminalPaneID
                {
                    existing.associatedTerminalPaneID = incoming
                    if let index = group.tabs.firstIndex(where: { $0.id == existing.id }) {
                        group.tabs[index] = existing
                    }
                    changed = true
                }
                // Reopening a cache file through a local path must preserve its
                // typed remote provenance. Remote matches were already selected
                // by exact identity, so no incoming open may retarget a tab.
                let effectiveIdentity =
                    existing.remoteResourceIdentity
                    ?? remoteResourceIdentity
                let effectiveTitle = documentTabTitle(
                    fileURL: normalizedURL,
                    remoteResourceIdentity: effectiveIdentity
                )
                if existing.remoteResourceIdentity != effectiveIdentity {
                    existing.remoteResourceIdentity = effectiveIdentity
                    if let index = group.tabs.firstIndex(where: { $0.id == existing.id }) {
                        group.tabs[index] = existing
                    }
                    changed = true
                }
                if existing.title != effectiveTitle {
                    existing.title = effectiveTitle
                    if let index = group.tabs.firstIndex(where: { $0.id == existing.id }) {
                        group.tabs[index] = existing
                    }
                    changed = true
                }
                if remoteResourceIdentity != nil,
                    existing.fileURL.standardizedFileURL != normalizedURL
                {
                    existing.fileURL = normalizedURL
                    if let index = group.tabs.firstIndex(where: { $0.id == existing.id }) {
                        group.tabs[index] = existing
                    }
                    changed = true
                }
                if selectingNewTab, group.selectedTabID != existing.id {
                    group.selectedTabID = existing.id
                    changed = true
                }
                guard changed else {
                    return (session, existing.id)
                }
                guard let layout = session.layout.replacingDocumentGroup(id: group.id, with: group) else {
                    return nil
                }
                session.layout = layout
                return (session, existing.id)
            }

            let tab = DocumentPane(
                fileURL: normalizedURL,
                title: title,
                associatedTerminalPaneID: liveIncomingAssociation,
                remoteResourceIdentity: remoteResourceIdentity
            )
            group.tabs.append(tab)
            if selectingNewTab {
                group.selectedTabID = tab.id
            }
            guard let layout = session.layout.replacingDocumentGroup(id: group.id, with: group) else {
                return nil
            }
            session.layout = layout
            return (session, tab.id)
        }

        let tab = DocumentPane(
            fileURL: normalizedURL,
            title: title,
            associatedTerminalPaneID: liveIncomingAssociation,
            remoteResourceIdentity: remoteResourceIdentity
        )
        session.layout = .split(
            TerminalSplit(
                orientation: .vertical,
                first: session.layout,
                second: .documentGroup(DocumentGroup(tabs: [tab], selectedTabID: tab.id)),
                firstFraction: 0.6
            ))
        return (session, tab.id)
    }

    static func documentTabTitle(
        fileURL: URL,
        remoteResourceIdentity: ResourceIdentity?
    ) -> String {
        guard let path = remoteResourceIdentity?.path.rawValue else {
            return fileURL.lastPathComponent
        }
        guard !path.isEmpty else {
            return fileURL.lastPathComponent
        }
        let title = (path as NSString).lastPathComponent
        return title.isEmpty ? fileURL.lastPathComponent : title
    }

    /// Selects the given tab in the session's document viewer. Never touches
    /// `activePaneID` — switching documents must not move terminal focus.
    /// Returns `nil` when the tab does not exist or is already selected.
    static func selectDocumentTab(
        tabID: DocumentPane.ID,
        in session: TerminalSession
    ) -> TerminalSession? {
        guard var group = session.layout.firstDocumentGroup,
            group.tab(id: tabID) != nil,
            group.selectedTabID != tabID
        else {
            return nil
        }
        group.selectedTabID = tabID
        guard let layout = session.layout.replacingDocumentGroup(id: group.id, with: group) else {
            return nil
        }
        var session = session
        session.layout = layout
        return session
    }

    /// Closes a document tab without moving terminal focus.
    static func closeDocumentTab(
        tabID: DocumentPane.ID,
        in session: TerminalSession,
        now: Date
    ) -> TerminalSession? {
        guard var group = session.layout.firstDocumentGroup,
            let index = group.tabs.firstIndex(where: { $0.id == tabID })
        else {
            return nil
        }
        var session = session

        group.tabs.remove(at: index)
        guard !group.tabs.isEmpty else {
            guard let layout = session.layout.removingDocumentGroup(id: group.id) else {
                return nil
            }
            session.layout = layout
            return session
        }

        if group.selectedTabID == tabID {
            group.selectedTabID = group.tabs[min(index, group.tabs.count - 1)].id
        }
        guard let layout = session.layout.replacingDocumentGroup(id: group.id, with: group) else {
            return nil
        }
        session.layout = layout
        return session
    }

    /// Navigates a tab in place, or selects an existing tab for the target file.
    static func replaceDocumentTab(
        tabID: DocumentPane.ID,
        fileURL: URL,
        in session: TerminalSession
    ) -> TerminalSession? {
        let normalizedURL = fileURL.standardizedFileURL
        guard var group = session.layout.firstDocumentGroup,
            let index = group.tabs.firstIndex(where: { $0.id == tabID }),
            !group.tabs[index].isReadOnlySnapshot
        else {
            return nil
        }
        var session = session

        if let existing = group.tab(forNormalizedURL: normalizedURL), existing.id != tabID {
            group.tabs.remove(at: index)
            group.selectedTabID = existing.id
            guard let layout = session.layout.replacingDocumentGroup(id: group.id, with: group) else {
                return nil
            }
            session.layout = layout
            return session
        }

        var tab = group.tabs[index]
        tab.fileURL = normalizedURL
        tab.title = normalizedURL.lastPathComponent
        tab.remoteResourceIdentity = nil
        group.tabs[index] = tab
        guard let layout = session.layout.replacingDocumentGroup(id: group.id, with: group) else {
            return nil
        }
        session.layout = layout
        return session
    }

    static func setActivePane(
        id paneID: TerminalPane.ID,
        in session: TerminalSession
    ) -> TerminalSession? {
        guard session.layout.pane(id: paneID) != nil,
            session.activePaneID != paneID
        else {
            return nil
        }

        var session = session
        session.activePaneID = paneID
        syncSessionChromeToActivePane(&session)
        return session
    }

    static func focusPane(
        _ direction: PaneFocusDirection,
        in session: TerminalSession
    ) -> TerminalSession? {
        var session = session
        let paneIDs = session.layout.paneIDs
        guard !paneIDs.isEmpty else {
            return nil
        }

        guard let activeIndex = paneIDs.firstIndex(of: session.activePaneID) else {
            session.activePaneID = paneIDs[0]
            return session
        }

        let nextIndex: Int
        switch direction {
        case .next:
            nextIndex = (activeIndex + 1) % paneIDs.count
        case .previous:
            nextIndex = (activeIndex - 1 + paneIDs.count) % paneIDs.count
        }

        session.activePaneID = paneIDs[nextIndex]
        syncSessionChromeToActivePane(&session)
        return session
    }

    static func focusPane(
        at index: Int,
        in session: TerminalSession
    ) -> TerminalSession? {
        let paneIDs = session.layout.paneIDs
        guard index >= 1, index <= paneIDs.count else {
            return nil
        }

        let targetID = paneIDs[index - 1]
        guard targetID != session.activePaneID else {
            return nil
        }

        var session = session
        session.activePaneID = targetID
        syncSessionChromeToActivePane(&session)
        return session
    }

    static func resizeSplit(
        id splitID: TerminalSplit.ID,
        firstFraction: Double,
        in session: TerminalSession
    ) -> TerminalSession? {
        guard session.layout.split(id: splitID) != nil else {
            return nil
        }

        let nextLayout = session.layout.resizingSplit(
            id: splitID,
            firstFraction: firstFraction
        )
        guard nextLayout != session.layout else {
            return nil
        }

        var session = session
        session.layout = nextLayout
        return session
    }

    static func resizeActiveSplit(
        by delta: Double,
        in session: TerminalSession
    ) -> TerminalSession? {
        guard
            let nextLayout = session.layout.resizingSplit(
                containing: session.activePaneID,
                by: delta
            ), nextLayout != session.layout
        else {
            return nil
        }

        var session = session
        session.layout = nextLayout
        return session
    }

    static func closePane(
        id paneID: TerminalPane.ID,
        in session: TerminalSession
    ) -> (result: PaneCloseResult, session: TerminalSession?)? {
        var session = session
        let paneIDs = session.layout.paneIDs
        guard let closedPaneIndex = paneIDs.firstIndex(of: paneID) else {
            return nil
        }

        guard paneIDs.count > 1 else {
            return (.session(session.id, paneIDs: paneIDs), nil)
        }

        guard let layout = session.layout.removingPane(id: paneID) else {
            return nil
        }

        let remainingPaneIDs = paneIDs.filter { $0 != paneID }
        let activeReplacementID: TerminalPane.ID
        if remainingPaneIDs.contains(session.activePaneID) {
            activeReplacementID = session.activePaneID
        } else {
            activeReplacementID =
                remainingPaneIDs[
                    min(closedPaneIndex, remainingPaneIDs.count - 1)
                ]
        }

        session.layout = layout
        session.activePaneID = activeReplacementID
        syncSessionChromeToActivePane(&session)
        return (.pane(paneID), session)
    }

    // MARK: - Move and swap

    /// Moves a pane to a workspace edge and focuses it.
    static func movePane(
        id paneID: TerminalPane.ID,
        toWorkspaceEdge edge: PaneMoveEdge,
        in session: TerminalSession
    ) -> TerminalSession? {
        guard let pane = session.layout.pane(id: paneID),
            session.layout.hasMultiplePanes,
            let remainder = session.layout.removingPane(id: paneID)
        else {
            return nil
        }

        let nextLayout = remainder.wrappedInRootSplit(adding: pane, on: edge)
        guard !nextLayout.isStructurallyEquivalent(to: session.layout) else {
            return nil
        }

        return applyingMovedLayout(nextLayout, focusing: paneID, in: session)
    }

    /// Moves a pane next to another pane and focuses it.
    static func movePane(
        id paneID: TerminalPane.ID,
        adjacentToPane targetID: TerminalPane.ID,
        onEdge edge: PaneMoveEdge,
        in session: TerminalSession
    ) -> TerminalSession? {
        guard paneID != targetID,
            let pane = session.layout.pane(id: paneID),
            session.layout.pane(id: targetID) != nil,
            session.layout.hasMultiplePanes,
            let remainder = session.layout.removingPane(id: paneID),
            let nextLayout = remainder.splittingPane(id: targetID, adding: pane, on: edge),
            !nextLayout.isStructurallyEquivalent(to: session.layout)
        else {
            return nil
        }

        return applyingMovedLayout(nextLayout, focusing: paneID, in: session)
    }

    /// Swaps two panes without changing split shape.
    static func swapPanes(
        firstID: TerminalPane.ID,
        secondID: TerminalPane.ID,
        in session: TerminalSession
    ) -> TerminalSession? {
        guard let nextLayout = session.layout.swappingPanes(firstID, secondID) else {
            return nil
        }

        return applyingMovedLayout(nextLayout, focusing: firstID, in: session)
    }

    static func canMovePane(
        id paneID: TerminalPane.ID,
        toWorkspaceEdge edge: PaneMoveEdge,
        in session: TerminalSession
    ) -> Bool {
        movePane(id: paneID, toWorkspaceEdge: edge, in: session) != nil
    }

    static func canMovePane(
        id paneID: TerminalPane.ID,
        adjacentToPane targetID: TerminalPane.ID,
        onEdge edge: PaneMoveEdge,
        in session: TerminalSession
    ) -> Bool {
        movePane(id: paneID, adjacentToPane: targetID, onEdge: edge, in: session) != nil
    }

    static func canSwapPanes(
        firstID: TerminalPane.ID,
        secondID: TerminalPane.ID,
        in session: TerminalSession
    ) -> Bool {
        swapPanes(firstID: firstID, secondID: secondID, in: session) != nil
    }

    private static func applyingMovedLayout(
        _ layout: TerminalPaneLayout,
        focusing paneID: TerminalPane.ID,
        in session: TerminalSession
    ) -> TerminalSession {
        var session = session
        session.layout = layout
        session.activePaneID = paneID
        syncSessionChromeToActivePane(&session)
        return session
    }

    static func recycleActivePane(
        in session: TerminalSession,
        now: Date,
        executionPlan: PaneExecutionPlan? = nil
    ) -> RecycleResult? {
        var session = session
        guard let activePane = session.activePane else {
            return nil
        }

        let recycledPane = TerminalPane(
            title: Self.freshPaneSeedTitle(from: activePane),
            workingDirectory: activePane.workingDirectory,
            color: activePane.color,
            lastAgentStateChangeAt: now,
            executionPlan: executionPlan ?? activePane.executionPlan
        )
        guard
            var layout = session.layout.replacingPane(
                id: activePane.id,
                with: .pane(recycledPane)
            )
        else {
            return nil
        }

        // Recycle mints a new pane ID; document tabs should follow it.
        if var group = layout.firstDocumentGroup {
            let needsRewrite = group.tabs.contains { $0.associatedTerminalPaneID == activePane.id }
            if needsRewrite {
                group.tabs = group.tabs.map { tab in
                    var tab = tab
                    if tab.associatedTerminalPaneID == activePane.id {
                        tab.associatedTerminalPaneID = recycledPane.id
                    }
                    return tab
                }
                layout = layout.replacingDocumentGroup(id: group.id, with: group) ?? layout
            }
        }

        session.layout = layout
        session.activePaneID = recycledPane.id
        syncSessionChromeToActivePane(&session)

        return RecycleResult(
            session: session,
            discardedPaneID: activePane.id
        )
    }

    static func updatePane(
        in session: TerminalSession,
        paneID: TerminalPane.ID,
        title: String?,
        workingDirectory: String?,
        progressReport: TerminalProgressReport? = nil,
        localHostnames: Set<String>
    ) -> TerminalSession? {
        var session = session
        guard var pane = session.layout.pane(id: paneID) else {
            return nil
        }

        // Terminals may re-emit identical OSC title/cwd reports every frame.
        // Keep a snapshot so redundant reports do not rebuild the layout.
        let originalPane = pane

        if let title {
            let sanitized = SessionStoreText.sanitizedTitle(title)
            if !sanitized.isEmpty {
                // Cache the live title even while the display title is frozen.
                pane.liveTerminalTitle = sanitized

                if case let .remote(host) = RemoteSessionDetector.detect(
                    title: sanitized,
                    localNames: localHostnames
                ) {
                    pane.remoteHost = host
                    if let pendingTarget = pane.pendingRemoteSSHTarget {
                        pane.remoteSSHTarget = pendingTarget
                        pane.hasConsumedManagedSSHWorkspaceOffer = false
                        pane.pendingRemoteSSHTarget = nil
                    } else if originalPane.remoteHost != host {
                        pane.remoteSSHTarget = nil
                        pane.hasConsumedManagedSSHWorkspaceOffer = false
                    }
                    pane.remoteConnectionHealth = .active
                }

                if !pane.isTitleUserEdited {
                    pane.title = sanitized
                }
            }
        }

        if let workingDirectory {
            switch pane.executionPlan {
            case .ssh:
                if let remoteDirectory = RemoteWorkingDirectoryValidator.validatedReportedDirectory(
                    workingDirectory
                ) {
                    pane.remoteWorkingDirectory = remoteDirectory
                }
            case .local:
                if let localDirectory = WorkingDirectoryValidator.validatedReportedDirectory(
                    workingDirectory
                ) {
                    pane.workingDirectory = localDirectory
                    pane.remoteHost = nil
                    pane.remoteSSHTarget = nil
                    pane.hasConsumedManagedSSHWorkspaceOffer = false
                    pane.pendingRemoteSSHTarget = nil
                    pane.remoteWorkingDirectory = nil
                    pane.remoteConnectionHealth = .active
                }
            }
        }

        if let progressReport {
            // OSC 9;4 carries no source/PID, so same-pane reports are
            // last-write-wins.
            pane.progressReport = progressReport.isVisible ? progressReport : nil
        }

        // Compare the fields this reducer can touch. `TerminalPane ==` is a
        // render-only subset and would miss live-title and health changes.
        guard
            pane.title != originalPane.title
                || pane.liveTerminalTitle != originalPane.liveTerminalTitle
                || pane.workingDirectory != originalPane.workingDirectory
                || pane.remoteHost != originalPane.remoteHost
                || pane.remoteSSHTarget != originalPane.remoteSSHTarget
                || pane.hasConsumedManagedSSHWorkspaceOffer != originalPane.hasConsumedManagedSSHWorkspaceOffer
                || pane.pendingRemoteSSHTarget != originalPane.pendingRemoteSSHTarget
                || pane.remoteWorkingDirectory != originalPane.remoteWorkingDirectory
                || pane.remoteConnectionHealth != originalPane.remoteConnectionHealth
                || pane.progressReport != originalPane.progressReport
        else {
            return nil
        }

        guard let layout = session.layout.replacingPane(id: paneID, with: .pane(pane)) else {
            return nil
        }

        session.layout = layout
        if session.activePaneID == paneID {
            syncSessionChromeToActivePane(&session)
        }
        return session
    }

    static func noteSubmittedCommand(
        in session: TerminalSession,
        paneID: TerminalPane.ID,
        command: String
    ) -> TerminalSession? {
        var session = session
        guard var pane = session.layout.pane(id: paneID) else {
            return nil
        }

        guard pane.remoteHost == nil,
            RemoteSSHCommandTarget.isSSHCommand(command)
        else {
            return nil
        }
        let target = RemoteSSHCommandTarget.parseManagedWorkspaceOffer(command)
        guard pane.pendingRemoteSSHTarget != target else {
            return nil
        }
        pane.pendingRemoteSSHTarget = target

        guard let layout = session.layout.replacingPane(id: paneID, with: .pane(pane)) else {
            return nil
        }
        session.layout = layout
        return session
    }

    static func recordRecentTerminalLink(
        in session: TerminalSession,
        paneID: TerminalPane.ID,
        value: String
    ) -> TerminalSession? {
        guard var pane = session.layout.pane(id: paneID), pane.recentLinks.record(value) else {
            return nil
        }
        var session = session
        guard let layout = session.layout.replacingPane(id: paneID, with: .pane(pane)) else {
            return nil
        }
        session.layout = layout
        return session
    }

    /// Pins a user/programmatic custom title on a pane and freezes it against
    /// the live terminal title. Returns nil if the pane is absent or the title
    /// sanitizes to empty (callers treat empty as "reset" via `resetPaneTitle`).
    ///
    /// Calls `syncSessionChromeToActivePane` when the renamed pane is active so
    /// the workspace title refreshes immediately. In a split, sync reads the
    /// pane's `liveTerminalTitle`, never its custom `title`, so the custom name
    /// can't leak into the workspace title (F6 — pane titles stay independent of
    /// the workspace title). On a LONE pane the pin deliberately becomes the
    /// workspace title — see the lone-pane carve-out in sync.
    static func renamePane(
        in session: TerminalSession,
        paneID: TerminalPane.ID,
        title: String
    ) -> TerminalSession? {
        let sanitized = SessionStoreText.sanitizedTitle(title)
        guard !sanitized.isEmpty,
            var pane = session.layout.pane(id: paneID)
        else {
            return nil
        }

        pane.title = sanitized
        pane.isTitleUserEdited = true

        var session = session
        guard let layout = session.layout.replacingPane(id: paneID, with: .pane(pane)) else {
            return nil
        }
        session.layout = layout
        if session.activePaneID == paneID {
            syncSessionChromeToActivePane(&session)
        }
        return session
    }

    /// Unpins a custom pane title and re-adopts the live title when available.
    static func resetPaneTitle(
        in session: TerminalSession,
        paneID: TerminalPane.ID
    ) -> TerminalSession? {
        guard var pane = session.layout.pane(id: paneID),
            pane.isTitleUserEdited
        else {
            return nil
        }

        pane.isTitleUserEdited = false
        if let live = pane.liveTerminalTitle, !live.isEmpty {
            pane.title = live
        } else {
            let basename = (pane.workingDirectory as NSString).lastPathComponent
            pane.title = basename.isEmpty ? pane.workingDirectory : basename
        }

        var session = session
        guard let layout = session.layout.replacingPane(id: paneID, with: .pane(pane)) else {
            return nil
        }
        session.layout = layout
        if session.activePaneID == paneID {
            syncSessionChromeToActivePane(&session)
        }
        return session
    }

    /// Clears stale agent chrome without touching pane title, cwd, or color.
    static func resetPaneAgentChromeToShell(
        in session: TerminalSession,
        paneID: TerminalPane.ID
    ) -> TerminalSession? {
        guard var pane = session.layout.pane(id: paneID) else {
            return nil
        }

        pane.agentKind = .shell
        pane.agentExecutionState = AgentKind.shell.initialSessionState.executionState ?? .idle
        pane.attentionReason = nil
        pane.progressReport = nil

        var session = session
        guard let layout = session.layout.replacingPane(id: paneID, with: .pane(pane)) else {
            return nil
        }
        session.layout = layout
        return session
    }

    static func setPaneColor(
        in session: TerminalSession,
        paneID: TerminalPane.ID,
        color: PaneColor?
    ) -> TerminalSession? {
        guard var pane = session.layout.pane(id: paneID), pane.color != color else {
            return nil
        }
        pane.color = color
        var session = session
        guard let layout = session.layout.replacingPane(id: paneID, with: .pane(pane)) else {
            return nil
        }
        session.layout = layout
        return session
    }

    private static func syncSessionChromeToActivePane(_ session: inout TerminalSession) {
        guard let activePane = session.activePane else {
            return
        }

        // Workspace title follows the active pane's live title, not its pinned
        // custom pane title (F6) — EXCEPT on a lone pane, which has no pane
        // title bar: the workspace bar is the only surface its pinned title
        // can show ("a single full-window pane stays bare — the workspace bar
        // already names it", INT-283 design). Only agent channels (local
        // runtime rename + bridge pane-rename) can pin a lone pane's title —
        // the pane-bar rename affordance needs 2+ panes — so this carve-out
        // changes no user-driven rename semantics. A user-renamed workspace
        // still wins over both.
        if !session.isTitleUserEdited {
            if !session.layout.hasMultiplePanes, activePane.isTitleUserEdited {
                session.title = activePane.title
            } else if let live = activePane.liveTerminalTitle {
                session.title = live
            } else if !activePane.isTitleUserEdited {
                session.title = activePane.title
            }
        }
        session.workingDirectory = activePane.workingDirectory
    }
}
