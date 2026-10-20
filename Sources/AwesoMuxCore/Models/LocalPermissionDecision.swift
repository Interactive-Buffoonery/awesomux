import Foundation
import UnicodeHygiene

public struct LocalPermissionTarget: Codable, Hashable, Sendable {
    public let runtimeID: UUID
    public let workspaceID: UUID
    public let paneID: UUID
    public let version: UUID

    public init(runtimeID: UUID, workspaceID: UUID, paneID: UUID, version: UUID) {
        self.runtimeID = runtimeID
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.version = version
    }
}

public struct LocalPermissionIdentity: Codable, Hashable, Sendable {
    public let target: LocalPermissionTarget
    public let providerSessionID: String
    public let invocationID: UUID
    public var revision: Int
}

public enum LocalPermissionChoice: String, Codable, Sendable, CaseIterable {
    case allow, deny
}

public enum LocalPermissionState: String, Codable, Sendable {
    case pending, recorded, delivering, delivered, cancelled, expired, unknown
}

public struct LocalPermissionRequest: Codable, Equatable, Sendable {
    public let target: LocalPermissionTarget
    public let providerSessionID: String
    public let invocationID: UUID
    public let revision: Int
    public let toolUseID: String?
    public let helperPID: Int32
    public let helperStartMicroseconds: UInt64
    public let expiresAt: Date
    public let choices: [LocalPermissionChoice]
    public var tool: String
    public var summary: String

    public var issuedAt: Date { expiresAt.addingTimeInterval(-120) }

    public var identity: LocalPermissionIdentity {
        .init(target: target, providerSessionID: providerSessionID, invocationID: invocationID, revision: revision)
    }

    public init(
        target: LocalPermissionTarget, providerSessionID: String, invocationID: UUID, toolUseID: String?,
        helperPID: Int32, helperStartMicroseconds: UInt64, expiresAt: Date, tool: String, summary: String
    ) {
        self.target = target
        self.providerSessionID = providerSessionID
        self.invocationID = invocationID
        revision = 1
        self.toolUseID = toolUseID
        self.helperPID = helperPID
        self.helperStartMicroseconds = helperStartMicroseconds
        self.expiresAt = expiresAt
        choices = [.allow, .deny]
        self.tool = tool
        self.summary = summary
    }

    public func isValid(now: Date) -> Bool {
        revision == 1 && helperPID > 1 && helperStartMicroseconds > 0 && expiresAt > now && expiresAt.timeIntervalSince(now) <= 125
            && choices == [.allow, .deny]
            && Self.validIdentifier(providerSessionID) && (toolUseID.map(Self.validIdentifier) ?? true)
            && !tool.isEmpty && tool.utf8.count <= 128 && summary.utf8.count <= 1024
            && tool == Self.boundedSummary(tool, bytes: 128)
            && summary == Self.boundedSummary(summary, bytes: 1024)
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    public static func boundedSummary(_ value: String, bytes: Int = 1024) -> String {
        let clean = UnicodeHygiene.sanitize(value, maxLength: bytes).unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        }
        var result = ""
        for scalar in clean {
            guard result.utf8.count + scalar.utf8.count <= bytes else { break }
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}

public struct LocalPermissionOutcome: Codable, Equatable, Sendable {
    public let identity: LocalPermissionIdentity
    public var state: LocalPermissionState
    public var choice: LocalPermissionChoice?
    public var source: String?  // Local-only. Remote authority is deliberately absent.
}

/// The single authority shared by local bridge ingress and file fallback.
/// Transport records never recreate authority after expiry or target retirement.
@MainActor
public final class LocalPermissionDecisionCore {
    private struct Entry {
        let request: LocalPermissionRequest
        var outcome: LocalPermissionOutcome
    }
    private var targets: Set<LocalPermissionTarget> = []
    private var sessions: [LocalPermissionTarget: String] = [:]
    private var sessionEvidenceAt: [LocalPermissionTarget: Date] = [:]
    private var entries: [UUID: Entry] = [:]
    private struct Progress {
        let session: String
        let timestamp: Date
        let toolUseID: String?
    }
    private var progress: [LocalPermissionTarget: Progress] = [:]
    private struct NativeProgressKey: Hashable {
        let target: LocalPermissionTarget
        let session: String
        let toolUseID: String
    }
    private var nativeProgress: [NativeProgressKey: Date] = [:]
    private var progressBlockedUntil: Date?
    private var seen: [LocalPermissionTarget: Set<UUID>] = [:]
    public static let capacity = 128

    public init() {}

    public func install(_ target: LocalPermissionTarget) { targets.insert(target) }

    public func retire(_ target: LocalPermissionTarget) {
        cancel(target: target)
        targets.remove(target)
        sessions.removeValue(forKey: target)
        sessionEvidenceAt.removeValue(forKey: target)
        seen.removeValue(forKey: target)
        progress.removeValue(forKey: target)
        nativeProgress = nativeProgress.filter { $0.key.target != target }
    }

    public func observeSession(_ session: String, target: LocalPermissionTarget, at timestamp: Date) {
        guard targets.contains(target), timestamp >= (sessionEvidenceAt[target] ?? .distantPast) else { return }
        if let previous = sessions[target], previous != session { cancel(target: target) }
        sessions[target] = session
        sessionEvidenceAt[target] = timestamp
    }

    public func observeProgress(session: String, target: LocalPermissionTarget, at timestamp: Date, toolUseID: String? = nil) {
        guard targets.contains(target) else { return }
        if let toolUseID {
            let key = NativeProgressKey(target: target, session: session, toolUseID: toolUseID)
            if nativeProgress[key] != nil || nativeProgress.count < Self.capacity {
                nativeProgress[key] = max(timestamp, nativeProgress[key] ?? .distantPast)
            } else {
                // A saturated evidence cache cannot silently forget a native
                // resolution. Fall through until all affected hooks have expired.
                progressBlockedUntil = max(progressBlockedUntil ?? .distantPast, timestamp.addingTimeInterval(125))
            }
        } else if timestamp >= (progress[target]?.timestamp ?? .distantPast) {
            progress[target] = Progress(session: session, timestamp: timestamp, toolUseID: nil)
        }
        for entry in entries.values
        where entry.request.target == target
            && entry.request.providerSessionID == session && timestamp >= entry.request.issuedAt
            && (toolUseID == nil || entry.request.toolUseID == toolUseID)
        {
            cancel(entry.request.identity)
        }
    }

    @discardableResult
    public func admit(_ request: LocalPermissionRequest, now: Date, helperAlive: Bool) -> Bool {
        sweep(now: now)
        guard targets.contains(request.target) else { return false }
        if let existing = entries[request.invocationID] { return existing.request == request }
        guard helperAlive, request.isValid(now: now), entries.count < Self.capacity,
            !(seen[request.target]?.contains(request.invocationID) ?? false),
            (seen[request.target]?.count ?? 0) < 4096
        else { return false }
        if let until = progressBlockedUntil, until > now { return false }
        if let toolID = request.toolUseID,
            let timestamp = nativeProgress[
                NativeProgressKey(target: request.target, session: request.providerSessionID, toolUseID: toolID)],
            timestamp >= request.issuedAt
        {
            return false
        }
        if let evidence = progress[request.target], evidence.session == request.providerSessionID,
            evidence.timestamp >= request.issuedAt,
            evidence.toolUseID == nil || evidence.toolUseID == request.toolUseID
        {
            return false
        }
        // Verified pane-capability hook ingress may establish the provider session
        // before its lifecycle JSONL reaches the app. A different live session
        // requires an observed session transition; delayed telemetry cannot mint it.
        guard sessions[request.target] == nil || sessions[request.target] == request.providerSessionID else { return false }
        sessions[request.target] = request.providerSessionID
        sessionEvidenceAt[request.target] = now
        seen[request.target, default: []].insert(request.invocationID)
        entries[request.invocationID] = Entry(request: request, outcome: .init(identity: request.identity, state: .pending))
        return true
    }

    public var requests: [LocalPermissionRequest] { entries.values.map(\.request) }

    public var pendingRequests: [LocalPermissionRequest] {
        entries.values.filter { $0.outcome.state == .pending }.map(\.request)
            .sorted { $0.expiresAt < $1.expiresAt }
    }

    public func outcome(_ identity: LocalPermissionIdentity) -> LocalPermissionOutcome? {
        guard let entry = entries[identity.invocationID], entry.request.identity == identity else { return nil }
        return entry.outcome
    }

    @discardableResult
    public func commit(
        _ identity: LocalPermissionIdentity, choice: LocalPermissionChoice, now: Date,
        helperAlive: Bool
    ) -> LocalPermissionState? {
        validate(identity, now: now, helperAlive: helperAlive)
        guard var entry = entries[identity.invocationID], entry.request.identity == identity else { return nil }
        if entry.outcome.state == .pending, entry.request.choices.contains(choice) {
            entry.outcome.state = .recorded
            entry.outcome.choice = choice
            entry.outcome.source = "Mac"
            entries[identity.invocationID] = entry
        }
        return entry.outcome.state
    }

    public func claimDelivery(_ identity: LocalPermissionIdentity, now: Date, helperAlive: Bool) -> LocalPermissionChoice? {
        validate(identity, now: now, helperAlive: helperAlive)
        guard var entry = entries[identity.invocationID], entry.request.identity == identity,
            entry.outcome.state == .recorded
        else { return nil }
        entry.outcome.state = .delivering
        entries[identity.invocationID] = entry
        return entry.outcome.choice
    }

    public func acknowledge(_ identity: LocalPermissionIdentity) {
        transition(identity, from: [.delivering], to: .delivered)
    }

    public func deliveryLost(_ identity: LocalPermissionIdentity) {
        transition(identity, from: [.delivering], to: .unknown)
    }

    public func cancel(_ identity: LocalPermissionIdentity) {
        transition(identity, from: [.pending, .recorded], to: .cancelled)
        transition(identity, from: [.delivering], to: .unknown)
    }

    public func cancel(target: LocalPermissionTarget) {
        for entry in entries.values where entry.request.target == target {
            cancel(entry.request.identity)
        }
    }

    public func sweep(now: Date) {
        nativeProgress = nativeProgress.filter { $0.value.addingTimeInterval(125) > now }
        if let until = progressBlockedUntil, until <= now { progressBlockedUntil = nil }
        for entry in entries.values where entry.request.expiresAt <= now {
            transition(entry.request.identity, from: [.pending, .recorded], to: .expired)
            transition(entry.request.identity, from: [.delivering], to: .unknown)
        }
        // Outcomes expire; bounded per-target tombstones survive until target
        // retirement. Exhaustion refuses new ingress rather than evicting IDs.
        entries = entries.filter { $0.value.request.expiresAt.addingTimeInterval(600) > now }
    }

    private func validate(_ identity: LocalPermissionIdentity, now: Date, helperAlive: Bool) {
        sweep(now: now)
        guard let entry = entries[identity.invocationID], entry.request.identity == identity else { return }
        if !helperAlive || !targets.contains(identity.target) || sessions[identity.target] != identity.providerSessionID {
            transition(identity, from: [.pending, .recorded], to: .cancelled)
            transition(identity, from: [.delivering], to: .unknown)
        }
    }

    private func transition(_ identity: LocalPermissionIdentity, from states: [LocalPermissionState], to state: LocalPermissionState) {
        guard var entry = entries[identity.invocationID], entry.request.identity == identity,
            states.contains(entry.outcome.state)
        else { return }
        entry.outcome.state = state
        entries[identity.invocationID] = entry
    }
}
