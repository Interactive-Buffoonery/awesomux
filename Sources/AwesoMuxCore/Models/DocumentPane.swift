import Foundation

/// A document tab, not a terminal pane. Agent, remote, and shell state lives
/// on `TerminalPane`.
public struct DocumentPane: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var fileURL: URL
    public var title: String
    /// Send/stage target. It may dangle after terminal close; callers validate
    /// it and fail closed rather than falling back to the active pane.
    public var associatedTerminalPaneID: TerminalPane.ID?
    /// Non-nil when `fileURL` is a local cached copy of a remote Markdown file.
    /// Remote snapshots are read-only; the origin string is user-facing.
    public var remoteSnapshotOrigin: String?

    public var isReadOnlySnapshot: Bool {
        remoteSnapshotOrigin != nil
    }

    public init(
        id: UUID = UUID(),
        fileURL: URL,
        title: String,
        associatedTerminalPaneID: TerminalPane.ID? = nil,
        remoteSnapshotOrigin: String? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.title = title
        self.associatedTerminalPaneID = associatedTerminalPaneID
        self.remoteSnapshotOrigin = remoteSnapshotOrigin
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
        self.selectedTabID = tabs.contains(where: { $0.id == selectedTabID })
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
        tabs.first(where: { $0.fileURL.standardizedFileURL == normalizedURL })
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
    private enum CodingKeys: String, CodingKey {
        case id
        case tabs
        case selectedTabID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tabs = try container.decode([DocumentPane].self, forKey: .tabs)
        // Keep decode catchable: empty groups are invalid, while a stale
        // selectedTabID is disposable UI state and clamps in init.
        guard !tabs.isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "DocumentGroup has no tabs; empty groups are invalid"
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
