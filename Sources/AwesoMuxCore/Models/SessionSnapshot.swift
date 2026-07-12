import Foundation
import os

public extension CodingUserInfoKey {
    /// Carries the snapshot's `schemaVersion` down to nested
    /// `TerminalSession.init(from:)` so the v1 legacy agent-state fold can be
    /// gated on the version (a `TerminalSession` decodes through a shared
    /// decoder but can't otherwise see the version, which lives on
    /// `SessionSnapshot`). Absent → treat as legacy v1 (fold enabled), so a bare
    /// `TerminalSession` decode keeps migrating session-level keys onto the
    /// active pane (INT-504 M3).
    static let snapshotSchemaVersion = CodingUserInfoKey(rawValue: "awesomux.snapshotSchemaVersion")!
}

public struct SessionSnapshot: Codable, Hashable, Sendable {
    private static let logger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "SessionSnapshot"
    )

    // v2 (INT-504): agent state relocated from the session to its panes. The
    // decode-time fold in `TerminalSession.init(from:)` is key-presence driven —
    // a v1 snapshot still carries session-level agent keys and folds them onto
    // the active pane — so the bump is primarily a forward-rejection marker
    // (older builds refuse a v2 snapshot rather than silently dropping pane state).
    // v3 (INT-562): `TerminalPaneLayout.document(DocumentPane)` case introduced.
    // Forward-rejection only — no data migration needed; v1/v2 snapshots never
    // contain a `.document` leaf, so they decode cleanly without any fold.
    // v4 (INT-561): `TerminalPane` gained a backend-neutral
    // `terminalSessionID` plus an opaque backend metadata blob for the
    // persistent-session command bridge. Missing/invalid IDs mint new durable
    // backend names during decode; the v1 agent fold remains pinned to `< 2`.
    // `pinnedSessionIDs` (INT-737): additive/tolerant like `recentlyClosed`
    // below — no schema bump needed.
    // v5 (INT-748): `.document` leaves became `.documentGroup` tab containers;
    // tabs carry `associatedTerminalPaneID`. Decode maps the legacy `document`
    // key to a single-tab group (shape layer, unconditional), and
    // `TerminalSession.init(from:)` backfills associations from split adjacency
    // and folds multiple groups into one (gated on the literal `< 5`).
    // v6 (INT-612): generated workspace titles carry agent-kind + index metadata
    // so locale changes do not make collision detection depend on persisted copy.
    public static let currentSchemaVersion = 6

    /// The schema version to assume when a snapshot carries NO `schemaVersion`
    /// key at all (a truly pre-versioned file). Defaulting to v1 routes such a
    /// file through the legacy agent-state fold — the safe direction, since a
    /// file old enough to lack the key predates per-pane state and any
    /// session-level agent keys it carries must migrate onto the active pane
    /// rather than be silently dropped. Both the persistence-layer version peek
    /// and `TerminalSession.init(from:)`'s `userInfo` fallback read THIS constant
    /// so the two ends of the version pipeline can never disagree on what
    /// "absent" means (INT-504 review).
    public static let assumedLegacyVersionWhenAbsent = 1

    public var schemaVersion: Int
    public var groups: [SessionGroup]
    public var selectedSessionID: TerminalSession.ID?
    /// Persisted LIFO cache backing ⌘+⇧+T "Reopen Closed Workspace". Tolerant
    /// to absence (pre-INT-415 snapshots) and to malformed individual entries
    /// — bad cache rows are dropped rather than archiving the whole snapshot.
    /// The field was added without its own schema bump (it is purely additive
    /// and `JSONDecoder` ignores unknown keys), so it round-trips across schema
    /// versions; the field rides along unchanged across later schema bumps.
    public var recentlyClosed: [RecentlyClosedWorkspace]
    /// Ordered pin list for the sidebar's synthetic Pinned section (INT-737).
    /// Tolerant to absence (pre-INT-737 snapshots) and to a malformed payload
    /// — decode failure drops to an empty pin list rather than archiving the
    /// whole snapshot, since a pin is disposable UI state, never data loss.
    public var pinnedSessionIDs: [TerminalSession.ID]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        groups: [SessionGroup],
        selectedSessionID: TerminalSession.ID?,
        recentlyClosed: [RecentlyClosedWorkspace] = [],
        pinnedSessionIDs: [TerminalSession.ID] = []
    ) {
        self.schemaVersion = schemaVersion
        self.groups = groups
        self.selectedSessionID = selectedSessionID
        self.recentlyClosed = recentlyClosed
        self.pinnedSessionIDs = pinnedSessionIDs
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case groups
        case selectedSessionID
        case recentlyClosed
        case pinnedSessionIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        guard schemaVersion <= Self.currentSchemaVersion else {
            Self.logger.error(
                "Unsupported future session snapshot schema version: found \(schemaVersion, privacy: .public), current \(Self.currentSchemaVersion, privacy: .public)"
            )
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported future session snapshot schema version: found \(schemaVersion), current \(Self.currentSchemaVersion)."
            )
        }

        self.schemaVersion = schemaVersion
        self.groups = try container.decode([SessionGroup].self, forKey: .groups)
        self.selectedSessionID = try container.decodeIfPresent(
            TerminalSession.ID.self,
            forKey: .selectedSessionID
        )
        self.recentlyClosed = Self.decodeRecentlyClosed(from: container)
        self.pinnedSessionIDs = (try? container.decodeIfPresent(
            [TerminalSession.ID].self,
            forKey: .pinnedSessionIDs
        )).flatMap { $0 } ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(groups, forKey: .groups)
        try container.encodeIfPresent(selectedSessionID, forKey: .selectedSessionID)
        // Omit the key entirely when empty so the on-disk JSON is byte-for-byte
        // unchanged for users who never close a workspace — keeps the digest
        // gate in `SessionPersistence` quiet in the common case.
        if !recentlyClosed.isEmpty {
            try container.encode(recentlyClosed, forKey: .recentlyClosed)
        }
        // Omit when empty for the same reason as recentlyClosed above: byte-stable
        // JSON for users who never pin a workspace, quiet persistence digest gate.
        if !pinnedSessionIDs.isEmpty {
            try container.encode(pinnedSessionIDs, forKey: .pinnedSessionIDs)
        }
    }

    /// Decode `recentlyClosed` permissively: missing key → empty array, bad
    /// individual entry → skipped. The buffer is disposable cache data and
    /// must never block active-workspace restore on a single bad row.
    private static func decodeRecentlyClosed(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> [RecentlyClosedWorkspace] {
        guard container.contains(.recentlyClosed) else {
            return []
        }
        guard var nested = try? container.nestedUnkeyedContainer(forKey: .recentlyClosed) else {
            return []
        }
        var entries: [RecentlyClosedWorkspace] = []
        var droppedCount = 0
        while !nested.isAtEnd {
            if let entry = try? nested.decode(RecentlyClosedWorkspace.self) {
                entries.append(entry)
            } else {
                // Advance past the malformed element. `SkipMalformedValue`
                // accepts any concrete JSON value shape so the container
                // index moves forward and decode can continue.
                droppedCount += 1
                _ = try? nested.decode(SkipMalformedValue.self)
            }
        }
        if droppedCount > 0 {
            // Silent row-dropping hid corruption in the reopen cache; leave a
            // breadcrumb so a recurring loss is diagnosable (observability).
            logger.error(
                "dropped \(droppedCount, privacy: .public) malformed recentlyClosed entries during snapshot decode"
            )
        }
        return entries
    }
}

/// Sink type used to advance an `UnkeyedDecodingContainer` past any JSON
/// value shape (null, bool, number, string, array, object) without inspecting
/// it. Used to skip malformed `recentlyClosed` rows during tolerant decode.
private struct SkipMalformedValue: Decodable {
    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer() {
            if single.decodeNil() { return }
            if (try? single.decode(Bool.self)) != nil { return }
            if (try? single.decode(Int.self)) != nil { return }
            if (try? single.decode(Double.self)) != nil { return }
            if (try? single.decode(String.self)) != nil { return }
        }
        // Sub-container decode advances the parent on initialization; no
        // further action needed once one matches.
        if (try? decoder.unkeyedContainer()) != nil { return }
        _ = try? decoder.container(keyedBy: AnyCodingKey.self)
    }

    private struct AnyCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
        init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
    }
}
