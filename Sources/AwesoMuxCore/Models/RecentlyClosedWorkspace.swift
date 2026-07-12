import Foundation

/// A closed workspace snapshot for reopening fresh panes with the same layout.
public struct RecentlyClosedWorkspace: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let title: String
    public let syntheticTitle: SyntheticSessionTitle?
    public let isTitleUserEdited: Bool
    public let agentKind: AgentKind
    public let layout: TerminalPaneLayout
    public let activePaneID: TerminalPane.ID
    public let groupID: SessionGroup.ID
    public let groupName: String
    /// The owning group's declared SSH target at close time, so reopening the
    /// last workspace of a since-deleted remote group recreates it REMOTE
    /// instead of silently local (INT-773) — the target is otherwise
    /// unrecoverable (INT-767). Deliberately NOT defaulted in the init:
    /// a defaulted param at a rebuild site is how the tag got dropped in the
    /// first place (INT-775 trap family).
    public let groupRemote: RemoteTarget?
    public let indexInGroup: Int
    public let closedAt: Date

    public init(
        sessionID: UUID,
        title: String,
        syntheticTitle: SyntheticSessionTitle? = nil,
        isTitleUserEdited: Bool,
        agentKind: AgentKind,
        layout: TerminalPaneLayout,
        activePaneID: TerminalPane.ID,
        groupID: SessionGroup.ID,
        groupName: String,
        groupRemote: RemoteTarget?,
        indexInGroup: Int,
        closedAt: Date
    ) {
        self.sessionID = sessionID
        self.title = title
        self.syntheticTitle = isTitleUserEdited ? nil : syntheticTitle
        self.isTitleUserEdited = isTitleUserEdited
        self.agentKind = agentKind
        self.layout = layout
        self.activePaneID = activePaneID
        self.groupID = groupID
        self.groupName = groupName
        self.groupRemote = groupRemote
        self.indexInGroup = indexInGroup
        self.closedAt = closedAt
    }

    public func localizedTitle(
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        syntheticTitle?.localizedTitle(bundle: bundle, locale: locale) ?? title
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case title
        case syntheticTitle
        case isTitleUserEdited
        case agentKind
        case layout
        case activePaneID
        case groupID
        case groupName
        case groupRemote
        case indexInGroup
        case closedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var layout = try container.decode(TerminalPaneLayout.self, forKey: .layout)

        // Recently closed entries store raw layouts, so legacy document leaves
        // need the same v5 migration as TerminalSession snapshots.
        let schemaVersion = (decoder.userInfo[.snapshotSchemaVersion] as? Int)
            ?? SessionSnapshot.assumedLegacyVersionWhenAbsent
        if schemaVersion < 5 {
            layout = DocumentGroupMigration.migratingLegacyDocumentLeaves(in: layout)
        }

        let title = try container.decode(String.self, forKey: .title)
        let isTitleUserEdited = try container.decode(Bool.self, forKey: .isTitleUserEdited)
        let agentKind = try container.decode(AgentKind.self, forKey: .agentKind)
        let syntheticTitle: SyntheticSessionTitle?
        if schemaVersion < 6 {
            syntheticTitle = isTitleUserEdited
                ? nil
                : SyntheticSessionTitle.inferred(
                    from: title,
                    preferredAgentKind: agentKind
                )
        } else {
            syntheticTitle = try container.decodeIfPresent(
                SyntheticSessionTitle.self,
                forKey: .syntheticTitle
            )
        }

        self.init(
            sessionID: try container.decode(UUID.self, forKey: .sessionID),
            title: title,
            syntheticTitle: syntheticTitle,
            isTitleUserEdited: isTitleUserEdited,
            agentKind: agentKind,
            layout: layout,
            activePaneID: try container.decode(TerminalPane.ID.self, forKey: .activePaneID),
            groupID: try container.decode(SessionGroup.ID.self, forKey: .groupID),
            groupName: try container.decode(String.self, forKey: .groupName),
            // Additive & tolerant like `SessionGroup.remote`: absent (pre-fix
            // entries) and malformed shapes both collapse to nil — a bad cache
            // row must not archive the whole snapshot (see SessionSnapshot's
            // recentlyClosed contract).
            groupRemote: (try? container.decodeIfPresent(RemoteTarget.self, forKey: .groupRemote)) ?? nil,
            indexInGroup: try container.decode(Int.self, forKey: .indexInGroup),
            closedAt: try container.decode(Date.self, forKey: .closedAt)
        )
    }
}
