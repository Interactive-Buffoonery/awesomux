import AwesoMuxCore
import AwesoMuxLocalAPI
import AwesoMuxLocalAPIAccess
import Foundation
import Darwin

struct CompanionTerminalCreateRequest: Decodable, Sendable {
    let workspaceID: UUID?

    private struct Envelope: Decodable {
        let schemaVersion: Int
        let requestID: UUID
        let operation: String
        let connectionID: UUID
        let profile: String?
    }

    static func decode(_ object: [String: Any]) throws -> Self {
        let required: Set<String> = ["schemaVersion", "requestID", "operation", "connectionID"]
        guard Set(object.keys).subtracting(["profile", "workspaceID"]) == required,
            object["profile"] == nil || object["profile"] is String,
            object["workspaceID"] == nil || object["workspaceID"] is String,
            let data = try? JSONSerialization.data(withJSONObject: object),
            let envelope = try? LocalAPIContract.decoder().decode(Envelope.self, from: data),
            envelope.operation == CompanionTerminalCreate.operation,
            let request = try? LocalAPIContract.decoder().decode(Self.self, from: data)
        else { throw LocalAPIError.invalidRequest }
        guard envelope.schemaVersion == LocalAPIContract.version else { throw LocalAPIError.unsupportedVersion }
        return request
    }
}

struct CompanionTerminalCreateResponse: Encodable {
    let schemaVersion = LocalAPIContract.version
    let requestID: UUID
    let profile: String
    let appInstanceID: UUID
    let capturedAt: Date
    let createdTerminal: CompanionTerminalCreated
}

@MainActor
enum CompanionTerminalCreate {
    nonisolated static let operation = "create_terminal"

    static func apply(
        request: CompanionTerminalCreateRequest, store: SessionStore, defaultGroup: String,
        authority: LocalAPIRuntimeAuthority, certificateFingerprint: Data,
        lease: LocalAPIAuthorizationLease, deadline: ContinuousClock.Instant
    ) throws -> CompanionTerminalCreated {
        try authority.performCompanionTerminalOperation(
            workspaceID: request.workspaceID, requiresInput: true, certificateFingerprint: certificateFingerprint, lease: lease
        ) {
            guard !Task.isCancelled else { throw LocalAPIError.cancelled }
            guard ContinuousClock.now < deadline else { throw LocalAPIError.timeout }
            return try store.createCompanionTerminal(workspaceID: request.workspaceID, defaultGroup: defaultGroup)
        }
    }
}

@MainActor
enum CompanionTerminalOpen {
    static func waitForSocket(at path: String, deadline: ContinuousClock.Instant) async throws {
        guard ContinuousClock.now < deadline else { throw LocalAPIError.timeout }
        let directory = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { throw LocalAPIError.terminalUnavailable }
        let descriptor = open(directory, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw LocalAPIError.terminalUnavailable }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == geteuid() else {
            close(descriptor)
            throw LocalAPIError.terminalUnavailable
        }
        let operation = CompanionNetworkOperation<Void>()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
        source.setCancelHandler { close(descriptor) }
        source.setEventHandler {
            if FileManager.default.fileExists(atPath: path) { operation.resolve(.success(())) }
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let remaining = ContinuousClock.now.duration(to: deadline).components
        timer.schedule(deadline: .now() + max(0, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18))
        timer.setEventHandler { operation.resolve(.failure(LocalAPIError.timeout)) }
        source.activate()
        timer.activate()
        defer {
            source.cancel()
            timer.cancel()
        }
        try await operation.wait {
            // Check after subscribing so creation between lookup and watch is
            // covered, including a daemon that was already running.
            if FileManager.default.fileExists(atPath: path) { operation.resolve(.success(())) }
        }
    }

    static func prepare(
        paneID: UUID, targetVersion: UUID, store: SessionStore,
        authority: LocalAPIRuntimeAuthority, certificateFingerprint: Data,
        lease: LocalAPIAuthorizationLease, deadline: ContinuousClock.Instant,
        hydrate: (TerminalSession, TerminalPane) throws -> Void
    ) throws -> LocalAPITerminalWatchTarget {
        guard let target = store.localAPITerminalWatchTarget(paneID: paneID) else { throw LocalAPIError.staleTarget }
        return try authority.performCompanionTerminalOperation(
            workspaceID: target.workspaceID, requiresInput: false, certificateFingerprint: certificateFingerprint, lease: lease
        ) {
            guard !Task.isCancelled else { throw LocalAPIError.cancelled }
            guard ContinuousClock.now < deadline else { throw LocalAPIError.timeout }
            let (workspace, pane, current) = try store.companionTerminalToOpen(paneID: paneID, targetVersion: targetVersion)
            try hydrate(workspace, pane)
            return current
        }
    }
}
