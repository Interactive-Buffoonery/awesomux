import Foundation

extension TerminalPane {
    // CodingKeys omits runtime-only state (`remoteHost`, `remoteSSHTarget`,
    // `hasConsumedManagedSSHWorkspaceOffer`, `pendingRemoteSSHTarget`,
    // `remoteConnectionHealth`, `remoteWorkingDirectory`,
    // `liveTerminalTitle`, and the four runtime-only agent fields
    // `lastAgentStateChangeAt` / `shellActivity` / `needsTerminalQuitConfirmation` /
    // `terminalPromptObserved` / `foregroundProcessLiveness`, plus
    // `progressReport`, `remoteReconnect`, and `recentLinks`) so
    // restored panes come back active/idle with no progress chrome until live
    // shell signals prove otherwise. The durable execution plan and four durable
    // agent fields persist.
    // Keep these in sync if stored properties change.
    private enum CodingKeys: String, CodingKey {
        case id
        case terminalSessionID
        case terminalBackendMetadata
        case title
        case isTitleUserEdited
        case workingDirectory
        case executionPlan
        case color
        case agentKind
        case agentExecutionState
        case attentionReason
        case unreadNotificationCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            terminalSessionID: Self.decodeTerminalSessionID(from: container),
            terminalBackendMetadata: Self.decodeTerminalBackendMetadata(from: container),
            title: try container.decode(String.self, forKey: .title),
            isTitleUserEdited: try container.decodeIfPresent(
                Bool.self,
                forKey: .isTitleUserEdited
            ) ?? false,
            workingDirectory: try container.decode(String.self, forKey: .workingDirectory),
            color: Self.decodeTolerantColor(from: container),
            agentKind: try container.decodeIfPresent(AgentKind.self, forKey: .agentKind) ?? .shell,
            agentExecutionState: Self.decodeTolerantExecutionState(from: container),
            attentionReason: try container.decodeIfPresent(
                AttentionReason.self,
                forKey: .attentionReason
            ),
            // Clamp at decode: a hand-edited/corrupt snapshot must not seed a
            // negative count that would mask a sibling pane's unread in the
            // session sum (runtime mutations are already max(0,…)-guarded).
            unreadNotificationCount: max(
                0,
                try container.decodeIfPresent(
                    Int.self,
                    forKey: .unreadNotificationCount
                ) ?? 0),
            executionPlan: try container.decodeIfPresent(
                PaneExecutionPlan.self,
                forKey: .executionPlan
            ) ?? .local
        )
        // Missing and explicit-null plans are both legacy "unknown" values.
        // Only a successfully decoded non-null plan may suppress the owning
        // group's migration fallback. Malformed non-null plans still throw so
        // remote routing corruption can never silently downgrade to local.
        hasExplicitExecutionPlan =
            try container.contains(.executionPlan)
            && !container.decodeNil(forKey: .executionPlan)
    }

    private static func decodeTerminalSessionID(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> TerminalSessionID {
        guard
            let rawValue = try? container.decodeIfPresent(
                String.self,
                forKey: .terminalSessionID
            )
        else {
            return .generate()
        }

        return TerminalSessionID(rawValue: rawValue) ?? .generate()
    }

    private static func decodeTerminalBackendMetadata(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> TerminalBackendMetadata {
        do {
            return try container.decodeIfPresent(
                TerminalBackendMetadata.self,
                forKey: .terminalBackendMetadata
            ) ?? .empty
        } catch {
            return .empty
        }
    }

    /// Decodes the pane's execution state leniently: an unknown raw value (a
    /// hand-edited snapshot, or one written by a newer build) falls back to
    /// `.idle` rather than throwing. Without this, a single corrupt inactive
    /// pane would fail the entire workspace snapshot decode into quarantine —
    /// `AttentionReason` already tolerates the same way (M5 / INT-504 review).
    private static func decodeTolerantExecutionState(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> AgentExecutionState? {
        do {
            return try container.decodeIfPresent(
                AgentExecutionState.self,
                forKey: .agentExecutionState
            )
        } catch {
            return .idle
        }
    }

    /// Decodes the pane color leniently: a value written by a newer build (an
    /// unknown `kind`, an unknown palette `name`, OR a structurally malformed
    /// color object) decodes to `nil` rather than throwing, so one forward-written
    /// pane can't fail the whole workspace snapshot into quarantine — mirrors
    /// `decodeTolerantExecutionState`. The `catch` is intentionally broad: any
    /// decode error from `PaneColor.init(from:)` is treated as "not a color this
    /// build understands" and silenced to `nil`.
    ///
    /// Scope: this guarantee applies to *current-schema* pane snapshots only.
    /// A future bump to the top-level `SessionSnapshot` schema version is gated
    /// separately in `SessionSnapshot` and is outside the scope of this decoder.
    private static func decodeTolerantColor(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> PaneColor? {
        do {
            return try container.decodeIfPresent(PaneColor.self, forKey: .color)
        } catch {
            return nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(terminalSessionID.rawValue, forKey: .terminalSessionID)
        if !terminalBackendMetadata.isEmpty {
            try container.encode(terminalBackendMetadata, forKey: .terminalBackendMetadata)
        }
        try container.encode(title, forKey: .title)
        try container.encode(isTitleUserEdited, forKey: .isTitleUserEdited)
        try container.encode(workingDirectory, forKey: .workingDirectory)
        try container.encode(executionPlan, forKey: .executionPlan)
        try container.encodeIfPresent(color, forKey: .color)
        try container.encode(agentKind, forKey: .agentKind)
        try container.encode(agentExecutionState, forKey: .agentExecutionState)
        try container.encodeIfPresent(attentionReason, forKey: .attentionReason)
        try container.encode(unreadNotificationCount, forKey: .unreadNotificationCount)
    }
}
