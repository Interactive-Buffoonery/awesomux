import AwesoMuxBridgeProtocol
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

/// Why a session was lifted out of its origin group into one of the sidebar's
/// synthetic top sections. Carried rather than a `Bool` because the two sections
/// announce different reasons, and a flag would make the rotor call a pinned row
/// "Needs input" — worse than the silence it replaces.
public enum SidebarLiftReason: Equatable, Hashable, Sendable {
    case needsInput
    case pinned
}

public enum SidebarVisibleRows {
    /// - Parameter titles: resolved workspace titles (the sidebar's coarse-
    ///   channel map — `SessionStore.sidebarResolvedTitles()`), keyed by
    ///   session ID. Present sessions name the row their tile shows; absent
    ///   ones fall back to storage. The default keeps pure-projection tests
    ///   free of store plumbing.
    public static func rows(
        attention: [LiftedSessionEntry] = [],
        pinned: [LiftedSessionEntry] = [],
        for entries: [SidebarGroupEntry],
        collapsedGroupIDs: Set<SessionGroup.ID>,
        isFiltering: Bool,
        titles: [TerminalSession.ID: String] = [:]
    ) -> [SidebarVisibleRow] {
        // No header row for either synthetic section: unlike a group, neither is
        // collapsible, so neither is a keyboard-nav target of its own.
        let liftedRows = (attention + pinned).map { liftedEntry in
            let session = liftedEntry.entry.session
            return SidebarVisibleRow(
                target: .session(session.id),
                label: titles[session.id] ?? session.title,
                sessionID: session.id
            )
        }
        return liftedRows
            + entries.flatMap { entry -> [SidebarVisibleRow] in
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
                            label: titles[sessionEntry.session.id] ?? sessionEntry.session.title,
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
    /// expanding groups in the source list. (Contrast
    /// `rows(attention:pinned:for:collapsedGroupIDs:isFiltering:)`, which honors
    /// collapse for the visible-row walk.)
    /// - Parameter titles: resolved workspace titles — see `rows`. The rotor
    ///   must name a workspace exactly as the row you land on does (WCAG
    ///   4.1.2, issue #327), so the body's coarse-channel map wins over the
    ///   potentially fresher struct title.
    public static func rotorEntries(
        attention: [LiftedSessionEntry] = [],
        pinned: [LiftedSessionEntry] = [],
        for entries: [SidebarGroupEntry],
        titles: [TerminalSession.ID: String] = [:]
    ) -> [SidebarWorkspaceRotorEntry] {
        let liftedEntries =
            attention.map { rotorEntry(for: $0, liftedBecause: .needsInput, titles: titles) }
            + pinned.map { rotorEntry(for: $0, liftedBecause: .pinned, titles: titles) }
        return liftedEntries
            + entries.flatMap { entry in
            entry.sessions.map { sessionEntry in
                SidebarWorkspaceRotorEntry(
                    id: sessionEntry.session.id,
                        label: rotorLabel(
                            for: sessionEntry.session,
                            title: titles[sessionEntry.session.id]
                        )
                )
            }
        }
    }

    private static func rotorEntry(
        for liftedEntry: LiftedSessionEntry,
        liftedBecause reason: SidebarLiftReason,
        titles: [TerminalSession.ID: String] = [:]
    ) -> SidebarWorkspaceRotorEntry {
        let session = liftedEntry.entry.session
        let originGroupName = liftedEntry.originGroup.name
        // The rotor label ends with the agent state, and a row genuinely waiting
        // on a human reads that state as "Needs input" — the same words the
        // lifted phrase opens with, so appending the tile's full phrase here
        // stutters them back to back. The tile escapes this because its value
        // puts "Workspace 1 of 3" between the two; the rotor has no such cushion.
        // Narrow on purpose: a pinned row, or one the Needs Input section still
        // holds by selection stickiness, has had no reason spoken yet and keeps
        // the full phrase.
        let stateAlreadyNamedTheReason =
            reason == .needsInput && session.agentRollup().state == .needsAttention
        return SidebarWorkspaceRotorEntry(
            id: session.id,
            label: rotorLabel(
                for: session,
                title: titles[session.id],
                originGroupPhrase: stateAlreadyNamedTheReason
                    ? originPhrase(originGroupName: originGroupName)
                    : originGroupPhrase(liftedBecause: reason, originGroupName: originGroupName)
            )
        )
    }

    /// VoiceOver rotor announcement for a workspace: title + agent + state, so
    /// cycling the rotor conveys what each workspace is and whether it needs
    /// attention — not just an opaque name. Mirrors the sidebar row's own
    /// accessibility phrasing (`title, agent, state`), using `effectiveChromeState`
    /// so a shell reads as Idle/Running rather than a raw agent state.
    ///
    /// - Parameters:
    ///   - title: the resolved title the row shows (the coarse-channel map).
    ///     Nil means "use the session's own display title" — the fallback when
    ///     no map value exists.
    ///   - originGroupPhrase: appended for a row lifted into a synthetic
    ///     section, so the rotor says why it sits above its group instead of
    ///     leaving the reordering unexplained. `rotorEntry(for:liftedBecause:)`
    ///     picks between the tile's full wording and the origin alone.
    static func rotorLabel(
        for session: TerminalSession,
        title: String? = nil,
        originGroupPhrase: String? = nil,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        // The agent name follows the rollup's winning pane so it matches the
        // state being announced — not the active pane's kind (INT-504 R1).
        let rollup = session.agentRollup()
        let label = workspaceAccessibilityLabel(
            title: title ?? session.displayTitle(bundle: bundle, locale: locale),
            agentKind: rollup.winningAgentKind,
            state: rollup.state,
            bundle: bundle,
            locale: locale
        )
        guard let originGroupPhrase else {
            return label
        }
        return label + ", " + originGroupPhrase
    }

    /// The VoiceOver fragment naming why a row was lifted and where it returns
    /// to. Lives here, in the one type both the rotor and the two synthetic
    /// section views already depend on, so each phrase has a single literal and
    /// the rotor cannot drift out of sync with the tile it describes.
    public static func originGroupPhrase(
        liftedBecause reason: SidebarLiftReason,
        originGroupName: String,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        switch reason {
        case .needsInput:
            String(
                localized: "Needs input, from \(originGroupName)",
                bundle: bundle,
                locale: locale,
                comment:
                    "Spoken on a workspace lifted into the sidebar's Needs Input section — both the row's accessibility value and its VoiceOver rotor label — naming the group it returns to. The argument is a user-chosen group name."
            )
        case .pinned:
            String(
                localized: "Pinned, from \(originGroupName)",
                bundle: bundle,
                locale: locale,
                comment:
                    "Spoken on a pinned sidebar workspace — both the row's accessibility value and its VoiceOver rotor label — naming the group it returns to. The argument is a user-chosen group name."
            )
        }
    }

    /// The origin alone, for the rotor row whose state fragment has already said
    /// why it was lifted. Same home as `originGroupPhrase(liftedBecause:…)` so
    /// both wordings stay one edit apart.
    static func originPhrase(
        originGroupName: String,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        String(
            localized: "from \(originGroupName)",
            bundle: bundle,
            locale: locale,
            comment:
                "Appended to a lifted sidebar workspace's VoiceOver rotor label when the state it just spoke already named why the row was lifted, so only the group it returns to is left to say. The argument is a user-chosen group name."
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
