import Foundation

public enum SidebarVisibleRowTarget: Equatable, Hashable, Sendable {
    case group(SessionGroup.ID)
    case session(TerminalSession.ID)
}

public struct SidebarVisibleRow: Equatable, Hashable, Sendable, Identifiable {
    public let target: SidebarVisibleRowTarget
    public let label: String
    public let sessionID: TerminalSession.ID?

    public var id: SidebarVisibleRowTarget { target }

    public init(
        target: SidebarVisibleRowTarget,
        label: String,
        sessionID: TerminalSession.ID? = nil
    ) {
        self.target = target
        self.label = label
        self.sessionID = sessionID
    }
}

public struct SidebarWorkspaceRotorEntry: Equatable, Hashable, Sendable, Identifiable {
    public let id: TerminalSession.ID
    public let label: String

    public init(id: TerminalSession.ID, label: String) {
        self.id = id
        self.label = label
    }
}

public enum SidebarVisibleRows {
    public static func rows(
        pinned: [PinnedSessionEntry] = [],
        for entries: [SidebarGroupEntry],
        collapsedGroupIDs: Set<SessionGroup.ID>,
        isFiltering: Bool
    ) -> [SidebarVisibleRow] {
        // No header row for Pinned: unlike a group, it isn't collapsible, so
        // it isn't a keyboard-nav target of its own.
        let pinnedRows = pinned.map { pinnedEntry in
            SidebarVisibleRow(
                target: .session(pinnedEntry.entry.session.id),
                label: pinnedEntry.entry.session.title,
                sessionID: pinnedEntry.entry.session.id
            )
        }
        return pinnedRows + entries.flatMap { entry -> [SidebarVisibleRow] in
            var rows = [
                SidebarVisibleRow(
                    target: .group(entry.group.id),
                    label: entry.group.name
                )
            ]

            let hidesSessions = !isFiltering && collapsedGroupIDs.contains(entry.group.id)
            guard !hidesSessions else {
                return rows
            }

            rows.append(
                contentsOf: entry.sessions.map { sessionEntry in
                    SidebarVisibleRow(
                        target: .session(sessionEntry.session.id),
                        label: sessionEntry.session.title,
                        sessionID: sessionEntry.session.id
                    )
                }
            )
            return rows
        }
    }

    /// Rotor entries over the flattened post-filter session list. No
    /// `collapsedGroupIDs`/`isFiltering` parameters by design: `entries` already
    /// reflects the active search projection, and the rotor deliberately ignores
    /// visual group collapse so VoiceOver can reach every workspace without first
    /// expanding groups in the source list. (Contrast `rows(for:collapsedGroupIDs:
    /// isFiltering:)`, which honors collapse for the visible-row walk.)
    public static func rotorEntries(
        pinned: [PinnedSessionEntry] = [],
        for entries: [SidebarGroupEntry]
    ) -> [SidebarWorkspaceRotorEntry] {
        let pinnedEntries = pinned.map { pinnedEntry in
            SidebarWorkspaceRotorEntry(
                id: pinnedEntry.entry.session.id,
                label: rotorLabel(for: pinnedEntry.entry.session)
            )
        }
        return pinnedEntries + entries.flatMap { entry in
            entry.sessions.map { sessionEntry in
                SidebarWorkspaceRotorEntry(
                    id: sessionEntry.session.id,
                    label: rotorLabel(for: sessionEntry.session)
                )
            }
        }
    }

    /// VoiceOver rotor announcement for a workspace: title + agent + state, so
    /// cycling the rotor conveys what each workspace is and whether it needs
    /// attention — not just an opaque name. Mirrors the sidebar row's own
    /// accessibility phrasing (`title, agent, state`), using `effectiveChromeState`
    /// so a shell reads as Idle/Running rather than a raw agent state.
    static func rotorLabel(
        for session: TerminalSession,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        // The agent name follows the rollup's winning pane so it matches the
        // state being announced — not the active pane's kind (INT-504 R1).
        let rollup = session.agentRollup()
        return workspaceAccessibilityLabel(
            title: session.displayTitle(bundle: bundle, locale: locale),
            agentKind: rollup.winningAgentKind,
            state: rollup.state,
            bundle: bundle,
            locale: locale
        )
    }

    public static func workspaceAccessibilityLabel(
        title: String,
        agentKind: AgentKind,
        state: AgentDisplayState,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        let agent = agentKind.localizedShortName(bundle: bundle, locale: locale)
        let state = state.localizedLabel(bundle: bundle, locale: locale)
        let format = String(
            localized: "%1$@, %2$@, %3$@",
            bundle: bundle,
            locale: locale,
            comment: "VoiceOver workspace summary. Arguments are workspace title, agent name, and state."
        )
        return String(format: format, locale: locale, arguments: [title, agent, state])
    }

    public static func target(
        after currentTarget: SidebarVisibleRowTarget?,
        in rows: [SidebarVisibleRow],
        offset: Int
    ) -> SidebarVisibleRowTarget? {
        guard !rows.isEmpty else {
            return nil
        }

        guard let currentTarget,
              let currentIndex = rows.firstIndex(where: { $0.target == currentTarget }) else {
            return offset < 0 ? rows.last?.target : rows.first?.target
        }

        let nextIndex = (currentIndex + offset).clamped(to: 0...(rows.count - 1))
        return rows[nextIndex].target
    }

    public static func firstTarget(in rows: [SidebarVisibleRow]) -> SidebarVisibleRowTarget? {
        rows.first?.target
    }

    public static func lastTarget(in rows: [SidebarVisibleRow]) -> SidebarVisibleRowTarget? {
        rows.last?.target
    }

    public static func sessionID(for target: SidebarVisibleRowTarget?) -> TerminalSession.ID? {
        guard case let .session(sessionID) = target else {
            return nil
        }
        return sessionID
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
