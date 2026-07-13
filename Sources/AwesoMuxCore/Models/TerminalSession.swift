import Foundation

public struct TerminalSession: Identifiable, Hashable, Sendable {
    public let id: UUID
    private var storedTitle: String
    public private(set) var syntheticTitle: SyntheticSessionTitle?
    public var title: String {
        get { displayTitle() }
        set {
            storedTitle = newValue
            syntheticTitle = nil
        }
    }

    public func displayTitle(
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        syntheticTitle?.localizedTitle(bundle: bundle, locale: locale) ?? storedTitle
    }
    public var workingDirectory: String
    public var isTitleUserEdited: Bool
    /// Per-workspace notification mute (INT-598). Gates only the interruptive
    /// channels (macOS banner + sound) — the workspace keeps its sidebar
    /// indicators, unread badges, and dock-badge contribution so state stays
    /// visible. Local-machine state: persisted in the session snapshot and
    /// discarded with the workspace.
    public var notificationsMuted: Bool
    public var layout: TerminalPaneLayout
    public var activePaneID: TerminalPane.ID

    public init(
        id: UUID = UUID(),
        title: String,
        workingDirectory: String,
        syntheticTitle: SyntheticSessionTitle? = nil,
        isTitleUserEdited: Bool = false,
        notificationsMuted: Bool = false,
        agentKind: AgentKind? = nil,
        agentState: AgentState? = nil,
        agentExecutionState: AgentExecutionState? = nil,
        attentionReason: AttentionReason? = nil,
        lastAgentStateChangeAt: Date? = nil,
        needsTerminalQuitConfirmation: Bool = false,
        shellActivity: ShellActivity = .idle,
        unreadNotificationCount: Int = 0,
        layout: TerminalPaneLayout? = nil,
        activePaneID: TerminalPane.ID? = nil,
        executionPlan: PaneExecutionPlan = .local
    ) {
        var resolvedLayout: TerminalPaneLayout
        if let layout {
            resolvedLayout = layout
        } else {
            resolvedLayout = .pane(
                TerminalPane(
                title: syntheticTitle?.localizedTitle() ?? title,
                workingDirectory: workingDirectory,
                agentKind: agentKind ?? .shell,
                agentState: agentState,
                agentExecutionState: agentExecutionState,
                attentionReason: attentionReason,
                lastAgentStateChangeAt: lastAgentStateChangeAt ?? Date(),
                shellActivity: shellActivity,
                needsTerminalQuitConfirmation: needsTerminalQuitConfirmation,
                    unreadNotificationCount: unreadNotificationCount,
                    executionPlan: executionPlan
            ))
        }

        // A session layout must contain at least one terminal pane. A document-only
        // layout is structurally invalid: sessions always root at a terminal, with
        // documents as auxiliary leaves. Fail loudly at construction so the bad
        // layout is caught at the call site rather than silently producing a session
        // with no active pane. Only the reducer should construct sessions with
        // non-trivial layouts, and it never builds doc-only roots.
        precondition(
            resolvedLayout.firstPane != nil,
            "TerminalSession layout must contain at least one terminal pane; "
                + "documents are auxiliary and cannot be a layout root"
        )

        let resolvedActivePaneID: TerminalPane.ID
        if let activePaneID, resolvedLayout.pane(id: activePaneID) != nil {
            resolvedActivePaneID = activePaneID
        } else {
            resolvedActivePaneID = resolvedLayout.firstPaneID
        }

        // When a layout is supplied AND session-level agent params come with it,
        // those params are legacy single-agent state (a migrated v1 snapshot, a
        // restore, or a reopened workspace) — fold them onto the active pane.
        // Modern per-pane reconstruction passes `agentKind: nil`, so the layout's
        // own decoded pane state is preserved untouched (INT-504 R5).
        if layout != nil,
           Self.hasSessionLevelAgentParams(
               agentKind: agentKind,
               agentState: agentState,
               agentExecutionState: agentExecutionState,
               attentionReason: attentionReason,
               needsTerminalQuitConfirmation: needsTerminalQuitConfirmation,
               shellActivity: shellActivity,
               unreadNotificationCount: unreadNotificationCount
           ) {
            resolvedLayout = resolvedLayout.mappingPanes { pane in
                guard pane.id == resolvedActivePaneID else { return pane }
                var folded = pane
                if let agentKind { folded.agentKind = agentKind }
                if let agentExecutionState {
                    folded.agentExecutionState = agentExecutionState
                } else if let executionState = agentState?.executionState {
                    folded.agentExecutionState = executionState
                }
                // Fold attention only when a caller passes it explicitly. The
                // legacy `agentState` display key must NOT resurrect `.unknown`
                // attention: R5 drops a stale prompt across the bump, and the
                // restore reducer is what clears attention on load (M3).
                if let attentionReason {
                    folded.attentionReason = attentionReason
                }
                if let lastAgentStateChangeAt {
                    folded.lastAgentStateChangeAt = lastAgentStateChangeAt
                }
                // Only overwrite the runtime/badge fields when the caller set a
                // non-default value. The Codable decode path always leaves these
                // at their defaults, so an unconditional write would zero the
                // active pane's OWN decoded unread/activity whenever a stray
                // legacy session key triggered the fold (M3).
                if shellActivity != .idle {
                    folded.shellActivity = shellActivity
                }
                if needsTerminalQuitConfirmation {
                    folded.needsTerminalQuitConfirmation = needsTerminalQuitConfirmation
                }
                if unreadNotificationCount != 0 {
                    folded.unreadNotificationCount = unreadNotificationCount
                }
                return folded
            }
        }

        self.id = id
        let acceptedSyntheticTitle = isTitleUserEdited ? nil : syntheticTitle
        self.storedTitle = acceptedSyntheticTitle?.canonicalTitle ?? title
        self.syntheticTitle = acceptedSyntheticTitle
        self.workingDirectory = workingDirectory
        self.isTitleUserEdited = isTitleUserEdited
        self.notificationsMuted = notificationsMuted
        self.layout = resolvedLayout
        self.activePaneID = resolvedActivePaneID
    }

    private static func hasSessionLevelAgentParams(
        agentKind: AgentKind?,
        agentState: AgentState?,
        agentExecutionState: AgentExecutionState?,
        attentionReason: AttentionReason?,
        needsTerminalQuitConfirmation: Bool,
        shellActivity: ShellActivity,
        unreadNotificationCount: Int
    ) -> Bool {
        agentKind != nil
            || agentState != nil
            || agentExecutionState != nil
            || attentionReason != nil
            || needsTerminalQuitConfirmation
            || shellActivity != .idle
            || unreadNotificationCount != 0
    }
}

public extension TerminalSession {
    var activePane: TerminalPane? {
        layout.pane(id: activePaneID) ?? layout.firstPane
    }

    /// Every pane in tree order. Source of all session-level rollups; collected
    /// in a single O(panes) tree walk.
    var panes: [TerminalPane] {
        var panes: [TerminalPane] = []
        layout.appendPanes(into: &panes)
        return panes
    }

    /// Visits each pane in tree order without allocating the `panes` array —
    /// for hot read-only loops (shell-activity refresh, notification eval).
    func forEachPane(_ body: (TerminalPane) -> Void) {
        layout.forEachPane(body)
    }

    /// The single typed projection every session-level reader consumes. Folds the
    /// per-pane agent snapshots into one rollup that carries pane ownership, so
    /// the sidebar glyph follows the pane that earned the loudest state instead of
    /// the active pane (INT-504 R1).
    func agentRollup(at now: Date = Date()) -> SessionAgentRollup {
        let snapshots = panes.map { $0.agentSnapshot(at: now) }
        return SessionAgentRollup.from(snapshots)
            ?? SessionAgentRollup(
                state: .idle,
                winningPaneID: activePaneID,
                winningAgentKind: .shell,
                unreadTotal: 0
            )
    }

    /// Loudest pane's RAW agent state (execution + attention, no shell collapse).
    /// Mirrors the pre-INT-504 session-level `agentState`: a shell pane running a
    /// command reads `.running` here, where `effectiveChromeState` would collapse
    /// it to idle. Folds over panes by display priority.
    var agentState: AgentState {
        panes.map(\.agentState).min { $0.priority < $1.priority } ?? .idle
    }

    /// Loudest pane's chrome-collapsed display state — what the sidebar badge
    /// shows (shell panes read idle/running keyed on debounced activity).
    var effectiveChromeState: AgentState {
        agentRollup().state
    }

    /// The active pane's kind — for the few genuinely active-pane reads (path
    /// bar, shell-feature gating). Attention/state display follows the rollup's
    /// `winningAgentKind`, NOT this.
    var activeAgentKind: AgentKind {
        activePane?.agentKind ?? .shell
    }

    var needsAcknowledgement: Bool {
        panes.contains { $0.attentionReason != nil }
    }

    /// Summed across panes for badge display. Flipped from a stored var to a
    /// computed rollup — every former write moved to the owning pane.
    var unreadNotificationCount: Int {
        panes.reduce(0) { $0 + $1.unreadNotificationCount }
    }

    /// Whether any pane would lose work if the app quit right now.
    func isQuitRisk(at now: Date = Date()) -> Bool {
        panes.contains { $0.isQuitRisk(at: now) }
    }

    /// Whether any pane would lose work if this session were CLOSED (destroyed,
    /// daemon session included) — see `TerminalPane.isCloseRisk`.
    func isCloseRisk(at now: Date = Date()) -> Bool {
        panes.contains { $0.isCloseRisk(at: now) }
    }
}

extension TerminalSession: Codable {
    // Encoding writes no session-level agent keys (post INT-504 those live on the
    // panes). The four agent keys below are decode-only legacy keys: a
    // pre-relocation (v1) snapshot stored agent state on the session, and the
    // memberwise init folds `agentKind`/`agentExecutionState`/`attentionReason`
    // onto the active pane. `agentState` is the even older display-only legacy
    // key. None are ever encoded. `attentionReason` is read so a live v1
    // permission prompt survives the bump (R5); the restore reducer applies the
    // actual preserve/clear policy. The legacy `unreadNotificationCount` is NOT
    // decoded — unread badges are not carried across the bump.
    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case syntheticTitle
        case workingDirectory
        case isTitleUserEdited
        case notificationsMuted
        case agentKind
        case agentExecutionState
        case attentionReason
        case agentState
        case layout
        case activePaneID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var layout = try container.decodeIfPresent(TerminalPaneLayout.self, forKey: .layout)

        // A decoded layout that contains no terminal pane (e.g. a hand-edited
        // doc-only root like `.documentGroup(...)`) is invalid — document groups
        // are auxiliary and must always be nested inside a split alongside at
        // least one terminal pane. Reject it here so the error propagates as a
        // DecodingError, which `SessionPersistence.load()`'s `do/catch` can
        // catch and quarantine. Without this guard the memberwise init below
        // would call `resolvedLayout.firstPaneID`, hitting a
        // `preconditionFailure` that is NOT catchable (C1).
        if let layout, layout.firstPane == nil {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "TerminalSession layout has no terminal pane; document-only layouts are invalid"
                )
            )
        }

        // Gate the legacy session-level agent-state fold on the snapshot schema
        // version (INT-504 M3). v1 snapshots stored agent state on the session;
        // those keys fold onto the active pane. v2+ snapshots store state per
        // pane and must TRUST the decoded pane state — a stray session-level key
        // in a hybrid/hand-edited v2 file must NOT clobber a pane's own state.
        // The version isn't on `TerminalSession`; it rides down from
        // `SessionSnapshot` via `decoder.userInfo`. Absent → treat as v1 so a
        // bare `TerminalSession` decode still migrates.
        // IMPORTANT: gate on the literal v1 threshold (< 2), NOT on
        // `< currentSchemaVersion`. A dynamic upper-bound would re-enable the
        // fold for every new schema bump — e.g. bumping to v3 (INT-562) would
        // incorrectly fold v2 per-pane state back onto the session (INT-504
        // regression). The fold is specifically a v1→v2 migration; later bumps
        // add new leaf kinds (like `.document`) that require no agent-state fold.
        let schemaVersion = (decoder.userInfo[.snapshotSchemaVersion] as? Int)
            ?? SessionSnapshot.assumedLegacyVersionWhenAbsent
        let foldsLegacyAgentState = schemaVersion < 2

        // v4→v5 (INT-748): legacy `.document` leaves already decoded into
        // single-tab groups (shape layer, in `TerminalPaneLayout.init(from:)`);
        // here the version-gated layer backfills each tab's terminal association
        // from split adjacency and folds multiple groups into one viewer.
        // IMPORTANT: literal `< 5`, same rationale as the `< 2` fold below — a
        // dynamic bound would re-run the backfill on every future bump and
        // resurrect associations that a v5+ snapshot legitimately recorded as
        // dangling (fail-closed).
        if schemaVersion < 5, let decoded = layout {
            layout = DocumentGroupMigration.migratingLegacyDocumentLeaves(in: decoded)
        }

        let legacyAgentState = foldsLegacyAgentState
            ? try container.decodeIfPresent(AgentState.self, forKey: .agentState)
            : nil

        let rawTitle = try container.decode(String.self, forKey: .title)
        let isTitleUserEdited = try container.decodeIfPresent(
            Bool.self,
            forKey: .isTitleUserEdited
        ) ?? false
        let activePaneID = try container.decodeIfPresent(UUID.self, forKey: .activePaneID)
        let decodedAgentKind = foldsLegacyAgentState
            ? try container.decodeIfPresent(AgentKind.self, forKey: .agentKind)
            : nil
        let activeAgentKind = activePaneID.flatMap { layout?.pane(id: $0)?.agentKind }
            ?? layout?.firstPane?.agentKind
            ?? decodedAgentKind
            ?? .shell
        let syntheticTitle: SyntheticSessionTitle?
        if schemaVersion < 6 {
            syntheticTitle = isTitleUserEdited
                ? nil
                : SyntheticSessionTitle.inferred(
                    from: rawTitle,
                    preferredAgentKind: activeAgentKind
                )
        } else {
            syntheticTitle = try container.decodeIfPresent(
                SyntheticSessionTitle.self,
                forKey: .syntheticTitle
            )
        }

        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            title: rawTitle,
            workingDirectory: try container.decode(String.self, forKey: .workingDirectory),
            syntheticTitle: syntheticTitle,
            isTitleUserEdited: isTitleUserEdited,
            // Additive key (INT-598) — absent in older snapshots, no schema
            // bump needed (`JSONDecoder` ignores unknown keys going forward,
            // and encode omits the key when false for byte-stability).
            notificationsMuted: try container.decodeIfPresent(
                Bool.self,
                forKey: .notificationsMuted
            ) ?? false,
            // Legacy (v1) → folded onto the active pane. v2 → not read at all, so
            // panes keep their own decoded state untouched.
            agentKind: decodedAgentKind,
            agentState: legacyAgentState,
            agentExecutionState: foldsLegacyAgentState
                ? try container.decodeIfPresent(
                    AgentExecutionState.self,
                    forKey: .agentExecutionState
                )
                : nil,
            // INT-504 R5: a legacy session-level attention reason folds onto the
            // active pane so a live v1 permission prompt survives the bump. The
            // restore reducer decides which reasons are kept (`.userInputRequired`
            // / `.permissionPrompt`) vs cleared as stale. Unread is still dropped.
            attentionReason: foldsLegacyAgentState
                ? try container.decodeIfPresent(
                    AttentionReason.self,
                    forKey: .attentionReason
                )
                : nil,
            layout: layout,
            activePaneID: activePaneID
        )

        // A true v1 session has no layout key. The memberwise initializer must
        // synthesize a pane for it, but that pane's default local plan is not
        // persisted evidence: restore still needs to inherit the group's
        // legacy remote target.
        if layout == nil, var synthesizedPane = activePane {
            synthesizedPane.hasExplicitExecutionPlan = false
            self.layout =
                self.layout.replacingPane(
                    id: synthesizedPane.id,
                    with: .pane(synthesizedPane)
                ) ?? self.layout
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(storedTitle, forKey: .title)
        try container.encodeIfPresent(syntheticTitle, forKey: .syntheticTitle)
        try container.encode(workingDirectory, forKey: .workingDirectory)
        try container.encode(isTitleUserEdited, forKey: .isTitleUserEdited)
        // Omit when false so snapshots for users who never mute stay
        // byte-for-byte unchanged (same rationale as `recentlyClosed`).
        if notificationsMuted {
            try container.encode(notificationsMuted, forKey: .notificationsMuted)
        }
        try container.encode(layout, forKey: .layout)
        try container.encode(activePaneID, forKey: .activePaneID)
    }
}
