import Foundation

/// A document tab, not a terminal pane. Agent, remote, and shell state lives
/// on `TerminalPane`.
public struct DocumentPane: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var fileURL: URL
    public var title: String
    /// Send/stage target. It may dangle after terminal close; callers validate
    /// it and fail closed rather than falling back to the active pane.
    public var associatedTerminalPaneID: TerminalPane.ID?
    /// Non-nil when `fileURL` is implementation storage for a remote Markdown
    /// resource. The typed identity, never the cache URL, is its provenance.
    public internal(set) var remoteResourceIdentity: ResourceIdentity?
    /// Non-nil when `fileURL` is an awesoMux-rendered agent transcript. Like
    /// `remoteResourceIdentity`, the typed identity is the provenance and the
    /// cache URL is only implementation storage.
    public internal(set) var agentTranscriptIdentity: AgentTranscriptIdentity?
    /// Non-nil when `fileURL` is an awesoMux-rendered branch diff. Same shape
    /// as the two above: the typed identity is the provenance and the cache URL
    /// is only implementation storage.
    public internal(set) var branchChangesIdentity: BranchChangesIdentity?

    /// Remote provenance, and nothing else.
    ///
    /// Three consumers read this as exactly that — `documentNudgeTarget`'s
    /// `.readOnlyRemoteSnapshot` denial, `WorkspacePaneCapabilities`' fold of
    /// `remoteProvenance` across a whole group, and copy that names remote
    /// hosts. A locally generated read-only document must therefore NOT widen
    /// it: doing so would disable the send bar on the transcript pane itself
    /// and strip `localFileAccess` from unrelated local tabs sharing the group.
    /// Non-editability is `isEditable`.
    public var isReadOnlySnapshot: Bool {
        remoteResourceIdentity != nil
    }

    /// Whether the user may change what this tab shows — write annotations into
    /// its file, or navigate it to a different file.
    ///
    /// False for every kind of document awesoMux owns rather than the user: a
    /// remote snapshot (whose edits could never reach the real file), a
    /// rendered agent transcript, and a rendered branch diff (both of whose
    /// files are regenerable cache, so an annotation written there is silently
    /// lost at the next render or prune).
    public var isEditable: Bool {
        remoteResourceIdentity == nil && agentTranscriptIdentity == nil
            && branchChangesIdentity == nil
    }

    public var remoteSnapshotOrigin: String? {
        remoteResourceIdentity?.remoteDisplayOrigin
    }

    public init(
        id: UUID = UUID(),
        fileURL: URL,
        title: String,
        associatedTerminalPaneID: TerminalPane.ID? = nil,
        remoteResourceIdentity: ResourceIdentity? = nil,
        agentTranscriptIdentity: AgentTranscriptIdentity? = nil,
        branchChangesIdentity: BranchChangesIdentity? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.title = title
        self.associatedTerminalPaneID = associatedTerminalPaneID
        self.agentTranscriptIdentity = agentTranscriptIdentity
        self.branchChangesIdentity = branchChangesIdentity
        // Runtime construction is a trusted programming boundary. Persisted
        // identities use the throwing Codable path before reaching this invariant.
        precondition(
            remoteResourceIdentity?.isSupportedRemoteMarkdownSnapshot != false,
            "A remote document requires a valid remote Markdown identity"
        )
        self.remoteResourceIdentity = remoteResourceIdentity
    }
}

extension DocumentPane: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case fileURL
        case title
        case associatedTerminalPaneID
        case remoteResourceIdentity
        case remoteSnapshotOrigin
        case agentTranscriptIdentity
        case branchChangesIdentity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion =
            (decoder.userInfo[.snapshotSchemaVersion] as? Int)
            ?? SessionSnapshot.assumedLegacyVersionWhenAbsent
        let containsTypedIdentity = container.contains(.remoteResourceIdentity)
        let containsLegacyOrigin = container.contains(.remoteSnapshotOrigin)
        let hasTypedIdentity =
            try containsTypedIdentity
            && !container.decodeNil(forKey: .remoteResourceIdentity)
        let hasLegacyOrigin =
            try containsLegacyOrigin
            && !container.decodeNil(forKey: .remoteSnapshotOrigin)

        if schemaVersion >= 7, containsLegacyOrigin {
            throw DecodingError.dataCorruptedError(
                forKey: .remoteSnapshotOrigin,
                in: container,
                debugDescription: "Schema-v7 document panes cannot contain legacy remote provenance."
            )
        }
        if schemaVersion >= 7, containsTypedIdentity, !hasTypedIdentity {
            throw DecodingError.dataCorruptedError(
                forKey: .remoteResourceIdentity,
                in: container,
                debugDescription: "A present remote resource identity cannot be null."
            )
        }
        if hasTypedIdentity, hasLegacyOrigin {
            throw DecodingError.dataCorruptedError(
                forKey: .remoteResourceIdentity,
                in: container,
                debugDescription: "A document pane cannot contain both typed and legacy remote provenance."
            )
        }

        let identity: ResourceIdentity?
        if hasTypedIdentity {
            identity = try container.decode(ResourceIdentity.self, forKey: .remoteResourceIdentity)
        } else if hasLegacyOrigin {
            let origin = try container.decode(String.self, forKey: .remoteSnapshotOrigin)
            identity = try Self.migrateLegacyRemoteOrigin(origin, in: container)
        } else {
            identity = nil
        }

        if let identity, !identity.isSupportedRemoteMarkdownSnapshot {
            throw DecodingError.dataCorruptedError(
                forKey: .remoteResourceIdentity,
                in: container,
                debugDescription: "A remote document requires a valid remote Markdown identity."
            )
        }

        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            fileURL: try container.decode(URL.self, forKey: .fileURL),
            title: try container.decode(String.self, forKey: .title),
            associatedTerminalPaneID: try container.decodeIfPresent(
                TerminalPane.ID.self,
                forKey: .associatedTerminalPaneID
            ),
            remoteResourceIdentity: identity,
            agentTranscriptIdentity: Self.decodeTolerantTranscriptIdentity(from: container),
            branchChangesIdentity: Self.decodeTolerantBranchChangesIdentity(from: container)
        )
    }

    /// Decodes transcript provenance leniently: an identity written by a newer
    /// build (an `AgentKind` this one has no case for) or a corrupted one drops
    /// the *field* rather than throwing, matching `decodeTolerantColor` on
    /// `TerminalPane`. The tab itself is still a real document pointing at a
    /// real file, and `DocumentGroup.init(from:)` would otherwise drop it whole.
    ///
    /// Residual, accepted: a tab that loses its identity this way becomes
    /// editable, so annotations could be written into a regenerable cache file
    /// and lost at the next prune. It takes a hand-edited or forward-written
    /// snapshot to reach, and losing the tab outright is the worse trade.
    private static func decodeTolerantTranscriptIdentity(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> AgentTranscriptIdentity? {
        // `(try? …) ?? nil` flattens the `AgentTranscriptIdentity??` that
        // `try?` wraps around an optional-returning decode. Load-bearing.
        (try? container.decodeIfPresent(
            AgentTranscriptIdentity.self,
            forKey: .agentTranscriptIdentity
        )) ?? nil
    }

    /// Same tolerance, same trade, as `decodeTolerantTranscriptIdentity`: a
    /// branch-changes identity a newer build wrote in a shape this one rejects
    /// drops the *field*, not the tab. The residual is identical — the tab
    /// becomes editable and an annotation written into it is lost at the next
    /// prune — and losing a real tab pointing at a real file is the worse trade.
    private static func decodeTolerantBranchChangesIdentity(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> BranchChangesIdentity? {
        // `(try? …) ?? nil` flattens the double optional `try?` wraps around an
        // optional-returning decode. Load-bearing.
        (try? container.decodeIfPresent(
            BranchChangesIdentity.self,
            forKey: .branchChangesIdentity
        )) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        if let remoteResourceIdentity,
            !remoteResourceIdentity.isSupportedRemoteMarkdownSnapshot
        {
            throw EncodingError.invalidValue(
                remoteResourceIdentity,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "A remote document requires a valid remote Markdown identity."
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(fileURL, forKey: .fileURL)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(associatedTerminalPaneID, forKey: .associatedTerminalPaneID)
        try container.encodeIfPresent(remoteResourceIdentity, forKey: .remoteResourceIdentity)
        // No validity guard, unlike `remoteResourceIdentity`: an
        // `AgentTranscriptIdentity` cannot be constructed or decoded invalid,
        // and it has no mutable members to invalidate afterwards.
        try container.encodeIfPresent(agentTranscriptIdentity, forKey: .agentTranscriptIdentity)
        // No validity guard, for the same reason as the transcript identity: a
        // `BranchChangesIdentity` cannot be constructed or decoded invalid, and
        // it has no mutable members to invalidate afterwards.
        try container.encodeIfPresent(branchChangesIdentity, forKey: .branchChangesIdentity)
    }

    private static func migrateLegacyRemoteOrigin(
        _ origin: String,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> ResourceIdentity {
        let match = [":~/", ":/"]
            .compactMap { separator in origin.range(of: separator).map { (separator, $0) } }
            .min { $0.1.lowerBound < $1.1.lowerBound }
        guard let match else {
            throw DecodingError.dataCorruptedError(
                forKey: .remoteSnapshotOrigin,
                in: container,
                debugDescription: "Legacy remote snapshot origin is malformed or ambiguous."
            )
        }
        let targetText = String(origin[..<match.1.lowerBound])
        let pathStart = origin.index(after: match.1.lowerBound)
        let path = String(origin[pathStart...])
        guard let target = RemoteTarget(parsing: targetText) else {
            throw DecodingError.dataCorruptedError(
                forKey: .remoteSnapshotOrigin,
                in: container,
                debugDescription: "Legacy remote snapshot origin has no valid SSH target."
            )
        }
        let identity = ResourceIdentity(
            location: .remote(target),
            path: ResourcePath(rawValue: path)
        )
        guard identity.isSupportedRemoteMarkdownSnapshot else {
            throw DecodingError.dataCorruptedError(
                forKey: .remoteSnapshotOrigin,
                in: container,
                debugDescription: "Legacy remote snapshot origin has no valid Markdown path."
            )
        }
        return identity
    }
}

public enum DocumentPaneAssociationPolicy: Sendable, Equatable {
    /// Capture the session's active terminal when the caller has no target.
    case captureActivePaneWhenNil
    /// Store nil when the caller has no safe target.
    case preserveNil
}

/// The tabbed document viewer in a session layout. It is never empty.
public struct DocumentGroup: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var tabs: [DocumentPane]
    public var selectedTabID: DocumentPane.ID

    public init(id: UUID = UUID(), tabs: [DocumentPane], selectedTabID: DocumentPane.ID) {
        precondition(!tabs.isEmpty, "DocumentGroup must contain at least one tab")
        self.id = id
        self.tabs = tabs
        self.selectedTabID =
            tabs.contains(where: { $0.id == selectedTabID })
            ? selectedTabID
            : tabs[0].id
    }

    public var selectedTab: DocumentPane? {
        tabs.first(where: { $0.id == selectedTabID })
    }

    public func tab(id: DocumentPane.ID) -> DocumentPane? {
        tabs.first(where: { $0.id == id })
    }

    public func tab(forNormalizedURL normalizedURL: URL) -> DocumentPane? {
        tabs.first(where: {
            $0.remoteResourceIdentity == nil
                && $0.fileURL.standardizedFileURL == normalizedURL
        })
    }

    public func tab(forRemoteResource identity: ResourceIdentity) -> DocumentPane? {
        tabs.first(where: { $0.remoteResourceIdentity == identity })
    }

    /// Returns nil when there is no other tab to select.
    public func adjacentTabID(offset: Int) -> DocumentPane.ID? {
        guard tabs.count > 1,
            let index = tabs.firstIndex(where: { $0.id == selectedTabID })
        else {
            return nil
        }
        let count = tabs.count
        return tabs[((index + offset) % count + count) % count].id
    }
}

extension DocumentGroup: Codable {
    static let emptyAfterRecoveryDescription =
        "DocumentGroup has no valid tabs after dropping malformed entries"

    private enum CodingKeys: String, CodingKey {
        case id
        case tabs
        case selectedTabID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var tabsContainer = try container.nestedUnkeyedContainer(forKey: .tabs)
        var tabs: [DocumentPane] = []
        while !tabsContainer.isAtEnd {
            let tabDecoder = try tabsContainer.superDecoder()
            do {
                tabs.append(try DocumentPane(from: tabDecoder))
            } catch {
                (decoder.userInfo[.snapshotDecodeRecoveryRecorder]
                    as? SessionSnapshotDecodeRecoveryRecorder)?.recordDroppedDocumentTab()
            }
        }
        // Keep decode catchable: empty groups are invalid, while a stale
        // selectedTabID is disposable UI state and clamps in init.
        guard !tabs.isEmpty else {
            throw EmptyDocumentGroupDecodingError()
        }
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            tabs: tabs,
            selectedTabID: try container.decodeIfPresent(DocumentPane.ID.self, forKey: .selectedTabID)
                ?? tabs[0].id
        )
    }
}

struct EmptyDocumentGroupDecodingError: Error {}
