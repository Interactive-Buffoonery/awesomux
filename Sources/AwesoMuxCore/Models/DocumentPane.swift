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

    public var isReadOnlySnapshot: Bool {
        remoteResourceIdentity != nil
    }

    public var remoteSnapshotOrigin: String? {
        remoteResourceIdentity?.remoteDisplayOrigin
    }

    public init(
        id: UUID = UUID(),
        fileURL: URL,
        title: String,
        associatedTerminalPaneID: TerminalPane.ID? = nil,
        remoteResourceIdentity: ResourceIdentity? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.title = title
        self.associatedTerminalPaneID = associatedTerminalPaneID
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
            remoteResourceIdentity: identity
        )
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
            } catch {}
        }
        // Keep decode catchable: empty groups are invalid, while a stale
        // selectedTabID is disposable UI state and clamps in init.
        guard !tabs.isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: Self.emptyAfterRecoveryDescription
                )
            )
        }
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            tabs: tabs,
            selectedTabID: try container.decodeIfPresent(DocumentPane.ID.self, forKey: .selectedTabID)
                ?? tabs[0].id
        )
    }
}
