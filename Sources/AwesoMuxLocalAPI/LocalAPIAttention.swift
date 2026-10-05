import CryptoKit
import Foundation

public enum LocalAPIAttentionChange: String, Codable, Sendable {
    case raised
    case resolved
}

public struct LocalAPIAttentionEvent: Codable, Sendable {
    public let id: UUID
    public let attentionID: UUID
    public let change: LocalAPIAttentionChange
    public let paneID: UUID
    public let workspaceID: UUID
    public let provider: String
    public let providerSessionID: String?
    public let targetVersion: UUID
    public let occurredAt: Date
    public let reason: String
    public let resolvedAt: Date?

    public init(
        id: UUID = UUID(), attentionID: UUID, change: LocalAPIAttentionChange,
        paneID: UUID, workspaceID: UUID, provider: String, providerSessionID: String?,
        targetVersion: UUID, occurredAt: Date, reason: String, resolvedAt: Date? = nil
    ) {
        self.id = id
        self.attentionID = attentionID
        self.change = change
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.provider = provider
        self.providerSessionID = providerSessionID
        self.targetVersion = targetVersion
        self.occurredAt = occurredAt
        self.reason = reason
        self.resolvedAt = resolvedAt
    }
}

public enum LocalAPIAttentionCursorStatus: String, Codable, Sendable {
    case initial
    case current
    case historyGap = "history_gap"
    case appRestarted = "app_restarted"
    case accessChanged = "access_changed"
}

public struct LocalAPIAttentionPage: Codable, Sendable {
    public let events: [LocalAPIAttentionEvent]
    public let nextCursor: String
    public let cursorStatus: LocalAPIAttentionCursorStatus
    public let hasMore: Bool
    public let currentStateRecoveryRequired: Bool

    public init(
        events: [LocalAPIAttentionEvent], nextCursor: String,
        cursorStatus: LocalAPIAttentionCursorStatus, hasMore: Bool
    ) {
        self.events = events
        self.nextCursor = nextCursor
        self.cursorStatus = cursorStatus
        self.hasMore = hasMore
        currentStateRecoveryRequired = cursorStatus != .initial && cursorStatus != .current
    }
}

/// Owned by the main-actor session store; no server-side consumer position.
public struct LocalAPIAttentionJournal {
    private struct Entry {
        let position: UInt64
        let event: LocalAPIAttentionEvent
    }

    private struct Cursor: Codable {
        let connectionID: UUID
        let globalRevision: UUID
        let connectionRevision: UUID
        let position: String
    }

    private let instanceID: UUID
    private let cursorKey = SymmetricKey(size: .bits256)
    private var entries: [Entry] = []
    private var position: UInt64 = 0

    public init(instanceID: UUID) {
        self.instanceID = instanceID
    }

    public mutating func append(_ event: LocalAPIAttentionEvent) {
        position += 1
        entries.append(Entry(position: position, event: event))
        if entries.count > LocalAPIContract.maximumAttentionEvents {
            entries.removeFirst(entries.count - LocalAPIContract.maximumAttentionEvents)
        }
    }

    public func page(
        cursor value: String?, limit: Int, lease: LocalAPIAuthorizationLease,
        liveTargetVersions: [UUID: UUID]
    ) throws -> LocalAPIAttentionPage {
        guard limit > 0 else { throw LocalAPIError.invalidRequest }
        var start = entries.first.map { $0.position - 1 } ?? position
        var status: LocalAPIAttentionCursorStatus = .initial
        if let value {
            guard value.utf8.count <= 2048 else { throw LocalAPIError.invalidCursor }
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, let cursorInstance = UUID(uuidString: String(parts[0])),
                let sealed = Data(base64Encoded: String(parts[1])), sealed.count >= 28
            else { throw LocalAPIError.invalidCursor }
            if cursorInstance != instanceID {
                status = .appRestarted
            } else {
                let cursor: Cursor
                do {
                    let box = try AES.GCM.SealedBox(combined: sealed)
                    let data = try AES.GCM.open(box, using: cursorKey)
                    cursor = try LocalAPIContract.decoder().decode(Cursor.self, from: data)
                } catch { throw LocalAPIError.invalidCursor }
                guard cursor.connectionID == lease.connectionID, cursor.position.utf8.count == 16,
                    let cursorPosition = UInt64(cursor.position, radix: 16), cursorPosition <= position
                else {
                    throw LocalAPIError.invalidCursor
                }
                start = cursorPosition
                if cursor.globalRevision != lease.globalRevision || cursor.connectionRevision != lease.connectionRevision {
                    status = .accessChanged
                } else if start < entries.first.map({ $0.position - 1 }) ?? position {
                    status = .historyGap
                } else {
                    status = .current
                }
            }
        }
        if status != .initial && status != .current {
            return LocalAPIAttentionPage(
                events: [], nextCursor: try encodeCursor(position: position, lease: lease),
                cursorStatus: status, hasMore: false
            )
        }
        let authorized = entries.filter { entry in
            let event = entry.event
            guard entry.position > start,
                lease.statusScope.allows(
                    paneID: event.paneID, workspaceID: event.workspaceID, targetVersion: event.targetVersion
                )
            else { return false }
            if case .exactTarget = lease.statusScope {
                return liveTargetVersions[event.paneID] == event.targetVersion
            }
            return true
        }
        let selected = Array(authorized.prefix(min(limit, LocalAPIContract.maximumAttentionPageSize)))
        let hasMore = authorized.count > selected.count
        let end = hasMore ? selected.last!.position : position
        return LocalAPIAttentionPage(
            events: selected.map(\.event), nextCursor: try encodeCursor(position: end, lease: lease),
            cursorStatus: status, hasMore: hasMore
        )
    }

    private func encodeCursor(position: UInt64, lease: LocalAPIAuthorizationLease) throws -> String {
        let data = try LocalAPIContract.encoder().encode(
            Cursor(
                connectionID: lease.connectionID, globalRevision: lease.globalRevision,
                connectionRevision: lease.connectionRevision, position: String(format: "%016llx", position)
            ))
        guard let sealed = try AES.GCM.seal(data, using: cursorKey).combined else { throw LocalAPIError.transportFailure }
        return instanceID.uuidString.lowercased() + "." + sealed.base64EncodedString()
    }
}
