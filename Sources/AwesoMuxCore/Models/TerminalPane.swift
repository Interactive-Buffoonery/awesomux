import Foundation

public struct TerminalPane: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var terminalSessionID: TerminalSessionID
    public var terminalBackendMetadata: TerminalBackendMetadata
    public var title: String
    /// True once the user (or a programmatic rename) pinned a custom title, so
    /// the live OSC 0/2 terminal title stops overwriting it. Mirrors
    /// `TerminalSession.isTitleUserEdited`. Reset clears it. Persisted.
    public var isTitleUserEdited: Bool
    public var workingDirectory: String
    /// Durable authority for where this pane executes and who owns its
    /// persistent terminal session. Observed title/connection metadata below
    /// may enrich presentation but never retarget this plan.
    public var executionPlan: PaneExecutionPlan
    /// Decode-only migration marker. Missing legacy plan state is represented
    /// as a local placeholder until a group-aware restore reducer replaces it.
    /// Excluded from Codable/equality/hash and discharged before restored state
    /// becomes usable.
    var hasExplicitExecutionPlan: Bool
    /// The pane's name-plate tint, shown on the per-pane title bar. `nil` = the
    /// default neutral chrome band; there is no inheritance. Persisted.
    public var color: PaneColor?
    /// The remote host when this pane is in an SSH/remote session, else nil.
    /// Detected from the terminal title and cleared by a local OSC 7 pwd event
    /// (see `RemoteSessionDetector` / `SessionStore.updatePane`). **Ephemeral —
    /// deliberately excluded from `Codable`:** restore retains declared location
    /// through `executionPlan`, while this observed signal starts empty until the
    /// live shell proves the connection's presentation state.
    public var remoteHost: String?
    /// Runtime-only SSH target captured from the submitted `ssh` command. This
    /// may be an SSH config alias, unlike `remoteHost`, which comes from the
    /// remote prompt.
    public var remoteSSHTarget: String?
    /// Runtime-only one-shot state for the automatic managed-workspace offer.
    /// The safely observed target remains available for an explicit conversion.
    public var hasConsumedManagedSSHWorkspaceOffer: Bool
    /// Runtime-only submitted SSH target waiting for the terminal title to prove
    /// the pane actually became remote.
    public var pendingRemoteSSHTarget: String?
    /// Runtime-only health for the current remote connection. This is intentionally
    /// excluded from persistence with `remoteHost`; restored panes start active
    /// until live terminal signals prove they are remote/stale.
    public var remoteConnectionHealth: RemoteConnectionHealth
    /// Runtime-only directory explicitly reported by the remote terminal through
    /// OSC 7 / Ghostty's PWD action. Title-derived paths must never populate this
    /// field because it authorizes relative remote Markdown resolution.
    public var remoteWorkingDirectory: String?
    /// Runtime-only cache of the most recent live OSC 0/2 terminal title, kept
    /// even while `isTitleUserEdited` freezes the displayed `title`. Reset reads
    /// it to re-adopt the current terminal title without a round-trip to the
    /// surface. Deliberately excluded from Codable/equality/hash like the other
    /// runtime-only fields — it changes on every prompt redraw and nothing
    /// renders it.
    public var liveTerminalTitle: String?

    // Agent state moved down from `TerminalSession` (INT-504): runtime events are
    // already pane-keyed, so the state they mutate belongs to the pane. The
    // session derives a loudest-pane rollup from these — see `SessionAgentRollup`.
    public var agentKind: AgentKind
    public var agentExecutionState: AgentExecutionState
    public var attentionReason: AttentionReason?
    public var unreadNotificationCount: Int
    /// Wall-clock time of the most recent execution-state mutation. Runtime-only;
    /// not persisted. Used to demote stale active states in quit-risk checks —
    /// see INT-217 for the underlying drift problem this guards against.
    public var lastAgentStateChangeAt: Date
    /// Runtime-only, debounced prompt-marker activity for shell presentation.
    /// Separate from `needsTerminalQuitConfirmation`: quit safety uses the raw
    /// immediate signal, while chrome uses this display-friendly state.
    public var shellActivity: ShellActivity
    /// Runtime-only mirror of libghostty's `ghostty_surface_needs_confirm_quit`
    /// — true when the prompt-marker signal reports the cursor is not at a
    /// prompt. Refreshed from the Ghostty runtime; never persisted. Complements
    /// `agentState` so shell panes running real work also get the quit-confirm
    /// prompt — see INT-216.
    public var needsTerminalQuitConfirmation: Bool
    /// Runtime-only sampled foreground-process liveness — the primary INT-217
    /// quit-risk signal. Set from the Ghostty runtime via the quit-confirmation
    /// sync seam; never persisted (excluded from Codable/equality like the other
    /// runtime-only fields). Default `.unsampled` = no live local process, the
    /// safe default for un-mounted panes (lazy-mount invariant).
    public var foregroundProcessLiveness: ForegroundProcessLiveness
    /// Runtime-only OSC 9;4 progress report. A restored pane starts absent until
    /// the live terminal process announces its current operation again.
    public var progressReport: TerminalProgressReport?
    /// Runtime-only reconnect affordance for a remote pane whose bridge died.
    /// `nil` = normal. Deliberately excluded from `Codable`: on restore the
    /// normal attach path runs and re-derives this fresh if the host is
    /// genuinely still down, so a persisted flag would have no reliable clear
    /// path for a re-attach to an existing daemon (see `CodingKeys`).
    public var remoteReconnect: RemoteReconnectState? = nil

    public init(
        id: UUID = UUID(),
        terminalSessionID: TerminalSessionID = .generate(),
        terminalBackendMetadata: TerminalBackendMetadata = .empty,
        title: String,
        isTitleUserEdited: Bool = false,
        workingDirectory: String,
        color: PaneColor? = nil,
        remoteHost: String? = nil,
        remoteSSHTarget: String? = nil,
        hasConsumedManagedSSHWorkspaceOffer: Bool = false,
        pendingRemoteSSHTarget: String? = nil,
        remoteConnectionHealth: RemoteConnectionHealth = .active,
        remoteWorkingDirectory: String? = nil,
        liveTerminalTitle: String? = nil,
        agentKind: AgentKind = .shell,
        agentState: AgentState? = nil,
        agentExecutionState: AgentExecutionState? = nil,
        attentionReason: AttentionReason? = nil,
        lastAgentStateChangeAt: Date = Date(),
        shellActivity: ShellActivity = .idle,
        needsTerminalQuitConfirmation: Bool = false,
        foregroundProcessLiveness: ForegroundProcessLiveness = .unsampled,
        progressReport: TerminalProgressReport? = nil,
        unreadNotificationCount: Int = 0,
        executionPlan: PaneExecutionPlan
    ) {
        self.id = id
        self.terminalSessionID = terminalSessionID
        self.terminalBackendMetadata = terminalBackendMetadata
        self.title = title
        self.isTitleUserEdited = isTitleUserEdited
        self.workingDirectory = workingDirectory
        self.executionPlan = executionPlan
        hasExplicitExecutionPlan = true
        self.color = color
        self.remoteHost = remoteHost
        self.remoteSSHTarget = remoteSSHTarget
        self.hasConsumedManagedSSHWorkspaceOffer = hasConsumedManagedSSHWorkspaceOffer
        self.pendingRemoteSSHTarget = pendingRemoteSSHTarget
        self.remoteConnectionHealth = remoteConnectionHealth
        self.remoteWorkingDirectory = remoteWorkingDirectory
        self.liveTerminalTitle = liveTerminalTitle
        self.agentKind = agentKind
        self.agentExecutionState = agentExecutionState
            ?? agentState?.executionState
            ?? agentKind.initialSessionState.executionState
            ?? .idle
        self.attentionReason = attentionReason ?? agentState?.attentionReason
        self.lastAgentStateChangeAt = lastAgentStateChangeAt
        self.shellActivity = shellActivity
        self.needsTerminalQuitConfirmation = needsTerminalQuitConfirmation
        self.foregroundProcessLiveness = foregroundProcessLiveness
        self.progressReport = progressReport
        self.unreadNotificationCount = unreadNotificationCount
    }

    public mutating func applyLegacyAgentState(
        _ state: AgentState,
        clearsAttentionForExecutionState: Bool
    ) {
        if let executionState = state.executionState {
            agentExecutionState = executionState
            if clearsAttentionForExecutionState {
                attentionReason = nil
            }
        } else if let attentionReason = state.attentionReason {
            self.attentionReason = attentionReason
        }
    }
}

public extension TerminalPane {
    /// Host identity used by remote presentation and conservative safety gates.
    /// A durable SSH plan always wins; title-derived observation is only a
    /// fallback for an ordinary local pane that the live terminal proves has
    /// entered SSH.
    var remotePresentationHost: String? {
        if let target = executionPlan.remoteTarget {
            return target.sshDestination
        }
        guard let remoteHost else {
            return nil
        }
        let trimmed = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Read-only projection of `agentExecutionState` + `attentionReason`, mirroring
    /// `TerminalSession.agentState` before the INT-504 relocation. Mutate the
    /// durable fields directly, or call `applyLegacyAgentState(_:_:)`.
    var agentState: AgentState {
        AgentDisplayState(
            executionState: agentExecutionState,
            attentionReason: attentionReason
        )
    }

    /// The display state the chrome should show for this pane. For agent panes
    /// it is `agentState`; for shells it collapses ordinary execution states to
    /// idle/running keyed on debounced `shellActivity`, but still surfaces an
    /// explicit attention reason or a terminal error.
    var effectiveChromeState: AgentState {
        guard agentKind == .shell else {
            return agentState
        }

        if attentionReason != nil {
            return agentState
        }

        switch agentExecutionState {
        case .error:
            return agentState
        case .done:
            // A shell's `.done` can be stale after an exited agent returns to
            // the prompt; never project it as active chrome. The prompt marker
            // can also remain away-from-prompt after a real Claude turn exits,
            // so a busy fallback would just swap the stuck checkmark for a stuck
            // play badge. `.error` still shows through; it has its own clear
            // path via clearStaleErrorState.
            return .idle
        case .idle, .running, .waiting, .thinking, .output:
            return shellActivity == .busy ? .running : .idle
        }
    }

    /// How long an active execution state (`.running` / `.thinking` / `.output`)
    /// is trusted before quit-risk checks treat it as stale and ignore it.
    /// Guards against `AgentState` drifting from process reality — see INT-217.
    static let staleAgentActivityThreshold: TimeInterval = 60

    /// Whether this pane would lose work if the app quit right now. Delegates to
    /// the pure `QuitRiskPolicy`: process liveness is primary, OSC-133
    /// away-from-prompt corroborates, agent-execution freshness is the fallback.
    func isQuitRisk(at now: Date = Date()) -> Bool {
        QuitRiskPolicy.decision(quitRiskInputs, at: now).isRisk
    }

    /// Whether CLOSING (destroying) this pane would lose work. Distinct from
    /// `isQuitRisk`: bridged panes survive app quit but not a close, which
    /// kills their daemon session too — see `QuitRiskPolicy.closeDecision`.
    func isCloseRisk(at now: Date = Date()) -> Bool {
        QuitRiskPolicy.closeDecision(quitRiskInputs, at: now).isRisk
    }

    private var quitRiskInputs: QuitRiskInputs {
        QuitRiskInputs(
            agentKind: agentKind,
            agentExecutionState: agentExecutionState,
            lastAgentStateChangeAt: lastAgentStateChangeAt,
            awayFromPrompt: needsTerminalQuitConfirmation,
            liveness: foregroundProcessLiveness
        )
    }

    /// The pane's contribution to a `SessionAgentRollup`.
    func agentSnapshot(at now: Date = Date()) -> PaneAgentSnapshot {
        PaneAgentSnapshot(
            paneID: id,
            agentKind: agentKind,
            state: effectiveChromeState,
            unread: unreadNotificationCount,
            isQuitRisk: isQuitRisk(at: now),
            needsAcknowledgement: attentionReason != nil,
            attentionReason: attentionReason
        )
    }

    // Equality covers identity + fields that directly render from the pane
    // value, but deliberately excludes runtime-only fields that render through
    // other projections (`shellActivity`, `needsTerminalQuitConfirmation`,
    // `lastAgentStateChangeAt`, `foregroundProcessLiveness`,
    // `remoteConnectionHealth`) — same exclusion as `Codable`. Chrome that
    // depends on those (e.g. a shell's busy/idle collapse) re-renders by
    // observing the session's `agentRollup`, NOT bare-pane equality; no view
    // diffs a `TerminalPane` directly (`ForEach` keys on `id`), so this can't
    // strand a render. Revisit if a view ever takes a `TerminalPane` as an
    // `Equatable` render trigger.
    //
    // The INT-561 command-bridge fields are excluded too: `terminalSessionID`
    // is durable backend identity that is 1:1 with `id` (a pane never changes
    // its session id), so it's redundant here; `terminalBackendMetadata` is
    // runtime-mutable (`empty` → `established` on attach) and nothing renders
    // it, so folding it into equality would spuriously re-render on establish —
    // the exact failure mode the runtime-field exclusion exists to prevent.
    public static func == (lhs: TerminalPane, rhs: TerminalPane) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.isTitleUserEdited == rhs.isTitleUserEdited
            && lhs.workingDirectory == rhs.workingDirectory
            && lhs.executionPlan == rhs.executionPlan
            && lhs.color == rhs.color
            && lhs.remoteHost == rhs.remoteHost
            && lhs.remoteSSHTarget == rhs.remoteSSHTarget
            && lhs.pendingRemoteSSHTarget == rhs.pendingRemoteSSHTarget
            && lhs.agentKind == rhs.agentKind
            && lhs.agentExecutionState == rhs.agentExecutionState
            && lhs.attentionReason == rhs.attentionReason
            && lhs.progressReport == rhs.progressReport
            && lhs.unreadNotificationCount == rhs.unreadNotificationCount
            && lhs.remoteReconnect == rhs.remoteReconnect
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(title)
        hasher.combine(isTitleUserEdited)
        hasher.combine(workingDirectory)
        hasher.combine(executionPlan)
        hasher.combine(color)
        hasher.combine(remoteHost)
        hasher.combine(remoteSSHTarget)
        hasher.combine(pendingRemoteSSHTarget)
        hasher.combine(agentKind)
        hasher.combine(agentExecutionState)
        hasher.combine(attentionReason)
        hasher.combine(progressReport)
        hasher.combine(unreadNotificationCount)
        hasher.combine(remoteReconnect)
    }
}
