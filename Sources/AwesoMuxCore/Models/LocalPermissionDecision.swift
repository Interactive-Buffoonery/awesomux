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

    public init(target: LocalPermissionTarget, providerSessionID: String, invocationID: UUID, revision: Int) {
        self.target = target
        self.providerSessionID = providerSessionID
        self.invocationID = invocationID
        self.revision = revision
    }
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
    public var remoteExpiresAt: Date { min(issuedAt.addingTimeInterval(60), expiresAt.addingTimeInterval(-5)) }

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
            && Self.completeSummary(tool, bytes: 128) != nil
            && Self.completeSummary(summary) != nil
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    /// Consent text must survive intact. Title normalization, trimming and
    /// clipping can hide or change the action that an approval would execute.
    public static func completeSummary(_ value: String, bytes: Int = 1024) -> String? {
        guard !value.isEmpty, value.utf8.count <= bytes,
            value.utf8.elementsEqual(value.precomposedStringWithCompatibilityMapping.utf8),
            value.utf8.elementsEqual(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8),
            value.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
                    && !UnicodeHygiene.isUnsafePathScalar($0)
                    && !UnicodeHygiene.isDisallowedScalar($0)
            }),
            UnicodeHygiene.containsVisibleScalar(value)
        else { return nil }
        return value
    }
}

public enum LocalPermissionAnswerSource: Codable, Equatable, Sendable {
    case mac
    case device(id: UUID, name: String)
}

public struct LocalPermissionOutcome: Codable, Equatable, Sendable {
    public let identity: LocalPermissionIdentity
    public var state: LocalPermissionState
    public var choice: LocalPermissionChoice?
    public var source: LocalPermissionAnswerSource?
}

public struct LocalPermissionRemoteReceipt: Equatable, Sendable {
    public enum Result: String, Sendable {
        case recorded, alreadyAnswered, expired, unknown, retryConflict, capacityExceeded
    }
    public let result: Result
    public let outcome: LocalPermissionOutcome?
}

/// The single authority shared by local bridge ingress and file fallback.
/// Transport records never recreate authority after expiry or target retirement.
@MainActor
public final class LocalPermissionDecisionCore {
    private struct Entry {
        let request: LocalPermissionRequest
        let remoteExpiresAt: Date
        var outcome: LocalPermissionOutcome
        var outputAttempted = false
    }
    private var targets: Set<LocalPermissionTarget> = []
    private var sessions: [LocalPermissionTarget: String] = [:]
    private var sessionEvidenceAt: [LocalPermissionTarget: Date] = [:]
    private var entries: [UUID: Entry] = [:]
    private struct ProgressKey: Hashable {
        let target: LocalPermissionTarget
        let session: String
    }
    private var progress: [ProgressKey: Date] = [:]
    private struct NativeProgressKey: Hashable {
        let target: LocalPermissionTarget
        let session: String
        let toolUseID: String
    }
    private var nativeProgress: [NativeProgressKey: Date] = [:]
    private var progressBlockedUntil: Date?
    private var seen: [LocalPermissionTarget: Set<UUID>] = [:]
    private struct RetryKey: Hashable { let deviceID: UUID; let retryID: UUID }
    private struct Retry {
        let identity: LocalPermissionIdentity
        let choice: LocalPermissionChoice
        let receipt: LocalPermissionRemoteReceipt
        let retainUntil: Date
    }
    private var retries: [RetryKey: Retry] = [:]
    public static let retryCapacity = 512
    public static let capacity = 128

    public init() {}

    public func install(_ target: LocalPermissionTarget) { targets.insert(target) }

    public func retire(_ target: LocalPermissionTarget) {
        cancel(target: target)
        targets.remove(target)
        sessions.removeValue(forKey: target)
        sessionEvidenceAt.removeValue(forKey: target)
        seen.removeValue(forKey: target)
        progress = progress.filter { $0.key.target != target }
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
        } else {
            let key = ProgressKey(target: target, session: session)
            if progress[key] != nil || progress.count < Self.capacity {
                progress[key] = max(timestamp, progress[key] ?? .distantPast)
            } else {
                // Foreign sessions cannot evict cancellation evidence. If an
                // event cannot be retained, refuse ingress through its lifetime.
                progressBlockedUntil = max(progressBlockedUntil ?? .distantPast, timestamp.addingTimeInterval(125))
            }
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
        if let timestamp = progress[ProgressKey(target: request.target, session: request.providerSessionID)],
            timestamp >= request.issuedAt
        {
            return false
        }
        // Verified pane-capability hook ingress may establish the provider session
        // before its lifecycle JSONL reaches the app. A different live session
        // requires an observed session transition; delayed telemetry cannot mint it.
        guard sessions[request.target] == nil || sessions[request.target] == request.providerSessionID else { return false }
        sessions[request.target] = request.providerSessionID
        sessionEvidenceAt[request.target] = max(sessionEvidenceAt[request.target] ?? .distantPast, request.issuedAt)
        seen[request.target, default: []].insert(request.invocationID)
        entries[request.invocationID] = Entry(
            request: request, remoteExpiresAt: min(request.remoteExpiresAt, now.addingTimeInterval(60)),
            outcome: .init(identity: request.identity, state: .pending))
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

    public func remoteExpiry(_ identity: LocalPermissionIdentity) -> Date? {
        guard let entry = entries[identity.invocationID], entry.request.identity == identity else { return nil }
        return entry.remoteExpiresAt
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
            entry.outcome.source = .mac
            entries[identity.invocationID] = entry
        }
        return entry.outcome.state
    }

    /// MainActor serializes expiry and both local/remote commits. A remote
    /// deadline affects only device actions, never the remaining Mac window.
    public func commitRemote(
        _ identity: LocalPermissionIdentity, choice: LocalPermissionChoice,
        deviceID: UUID, deviceName: String, retryID: UUID, now: Date, helperAlive: Bool
    ) -> LocalPermissionRemoteReceipt {
        validate(identity, now: now, helperAlive: helperAlive)
        let key = RetryKey(deviceID: deviceID, retryID: retryID)
        if let retry = retries[key] {
            guard retry.identity == identity, retry.choice == choice else {
                return .init(result: .retryConflict, outcome: nil)
            }
            return retry.receipt
        }
        guard let entry = entries[identity.invocationID], entry.request.identity == identity else {
            return .init(result: .unknown, outcome: nil)
        }
        guard retries.count < Self.retryCapacity else { return .init(result: .capacityExceeded, outcome: nil) }
        let result: LocalPermissionRemoteReceipt.Result
        if entry.outcome.state != .pending {
            result = .alreadyAnswered
        } else if now >= entry.remoteExpiresAt {
            result = .expired
        } else {
            _ = commit(identity, choice: choice, now: now, helperAlive: helperAlive)
            if var winner = entries[identity.invocationID], winner.outcome.state == .recorded {
                winner.outcome.source = .device(id: deviceID, name: deviceName)
                entries[identity.invocationID] = winner
                result = .recorded
            } else {
                result = .alreadyAnswered
            }
        }
        let receipt = LocalPermissionRemoteReceipt(result: result, outcome: outcome(identity))
        retries[key] = Retry(
            identity: identity, choice: choice, receipt: receipt,
            retainUntil: entry.request.expiresAt.addingTimeInterval(600))
        return receipt
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

    public func markOutputAttempted(_ identity: LocalPermissionIdentity) {
        guard var entry = entries[identity.invocationID], entry.request.identity == identity,
            entry.outcome.state == .delivering
        else { return }
        entry.outputAttempted = true
        entries[identity.invocationID] = entry
    }

    public func acknowledge(_ identity: LocalPermissionIdentity) {
        transition(identity, from: [.delivering], to: .delivered)
    }

    public func deliveryLost(_ identity: LocalPermissionIdentity) {
        transition(identity, from: [.delivering], to: .unknown)
    }

    public func cancel(_ identity: LocalPermissionIdentity) {
        if let entry = entries[identity.invocationID], entry.request.identity == identity,
            case .device? = entry.outcome.source, !entry.outputAttempted
        {
            transition(identity, from: [.delivering], to: .cancelled)
        }
        transition(identity, from: [.pending, .recorded], to: .cancelled)
        transition(identity, from: [.delivering], to: .unknown)
    }

    public func cancel(target: LocalPermissionTarget) {
        for entry in entries.values where entry.request.target == target {
            cancel(entry.request.identity)
        }
    }

    public func sweep(now: Date) {
        retries = retries.filter { $0.value.retainUntil > now }
        progress = progress.filter { $0.value.addingTimeInterval(125) > now }
        nativeProgress = nativeProgress.filter { $0.value.addingTimeInterval(125) > now }
        if let until = progressBlockedUntil, until <= now { progressBlockedUntil = nil }
        for entry in entries.values where entry.request.expiresAt <= now {
            if case .device? = entry.outcome.source, !entry.outputAttempted {
                transition(entry.request.identity, from: [.delivering], to: .expired)
            }
            transition(entry.request.identity, from: [.pending, .recorded], to: .expired)
            transition(entry.request.identity, from: [.delivering], to: .unknown)
        }
        // Outcomes expire; bounded per-target tombstones survive until target
        // retirement. Exhaustion refuses new ingress rather than evicting IDs.
        entries = entries.filter { $0.value.request.expiresAt.addingTimeInterval(600) > now }
    }

    public func validate(_ identity: LocalPermissionIdentity, now: Date, helperAlive: Bool) {
        sweep(now: now)
        guard let entry = entries[identity.invocationID], entry.request.identity == identity else { return }
        if !helperAlive || !targets.contains(identity.target) || sessions[identity.target] != identity.providerSessionID {
            cancel(identity)
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
