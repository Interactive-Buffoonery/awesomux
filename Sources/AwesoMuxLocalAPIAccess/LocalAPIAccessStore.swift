import AwesoMuxConfig
import AwesoMuxLocalAPI
import AwesoMuxLocalAPICredentials
import CryptoKit
import Darwin
import Foundation
import Observation
import SecureFileIO
import UnicodeHygiene

public struct LocalAPIConnectionGrant: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var label: String
    public let createdAt: Date
    public var credentialVerifier: Data
    public var revision: UUID
    public var statusScope: LocalAPITargetScope
    public var contextGrant: LocalAPIContextGrant?

    public init(
        id: UUID,
        label: String,
        createdAt: Date,
        credentialVerifier: Data,
        revision: UUID,
        statusScope: LocalAPITargetScope,
        contextGrant: LocalAPIContextGrant? = nil
    ) {
        self.id = id
        self.label = label
        self.createdAt = createdAt
        self.credentialVerifier = credentialVerifier
        self.revision = revision
        self.statusScope = statusScope
        self.contextGrant = contextGrant
    }
}

public struct LocalAPIAccessState: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let profile: String
    public let installationID: UUID
    public var globallyEnabled: Bool
    public var globalRevision: UUID
    public var connections: [LocalAPIConnectionGrant]

    public init(profile: String) {
        schemaVersion = Self.schemaVersion
        self.profile = profile
        installationID = UUID()
        globallyEnabled = false
        globalRevision = UUID()
        connections = []
    }
}

public struct LocalAPIPendingRegistration: Sendable {
    public let connection: LocalAPIConnectionGrant
    public let credential: Data
}

public enum LocalAPIAccessFailure: Error, Equatable, Sendable {
    case authorityUnavailable
    case preservedInvalidState
    case invalidLabel
    case invalidScope
    case connectionNotFound
    case persistenceFailed
    case credentialGenerationFailed
}

public final class LocalAPIRuntimeAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var state: LocalAPIAccessState

    public init(state: LocalAPIAccessState) {
        self.state = state
    }

    public var provider: LocalAPIAuthorizationProvider {
        LocalAPIAuthorizationProvider(
            authorize: { [weak self] request, expected in
                guard let self else { return .failure(.accessDisabled) }
                return self.lock.withLock { self.authorize(request, matching: expected) }
            },
            commit: { [weak self] request, lease, body in
                guard let self else { throw LocalAPIError.accessDisabled }
                return try self.lock.withLock {
                    guard self.state.globallyEnabled else { throw LocalAPIError.accessDisabled }
                    guard request.profile == self.state.profile,
                        request.connectionID == lease.connectionID,
                        self.state.globalRevision == lease.globalRevision,
                        let connection = self.state.connections.first(where: { $0.id == lease.connectionID }),
                        connection.revision == lease.connectionRevision,
                        connection.statusScope == lease.statusScope,
                        connection.contextGrant == lease.contextGrant
                    else { throw LocalAPIError.permissionDenied }
                    // The server retains this lease from credential authorization.
                    // Every policy change invalidates its revisions before another write.
                    return try body()
                }
            }
        )
    }

    public func replace(with state: LocalAPIAccessState) {
        lock.withLock { self.state = state }
    }

    public static func verifier(
        credential: Data,
        profile: String,
        installationID: UUID,
        connectionID: UUID
    ) -> Data {
        var input = Data("awesomux-local-api-credential-v1\u{0}".utf8)
        input.append(Data(profile.utf8))
        input.append(0)
        input.append(Data(installationID.uuidString.lowercased().utf8))
        input.append(0)
        input.append(Data(connectionID.uuidString.lowercased().utf8))
        input.append(0)
        input.append(credential)
        return Data(SHA256.hash(data: input))
    }

    private func authorize(
        _ request: LocalAPIRequest,
        matching expected: LocalAPIAuthorizationLease?
    ) -> Result<LocalAPIAuthorizationLease, LocalAPIError> {
        guard state.globallyEnabled else { return .failure(.accessDisabled) }
        guard request.profile == state.profile,
            let connectionID = request.connectionID,
            let encodedCredential = request.credential,
            let credential = LocalAPICredential.decode(encodedCredential),
            let connection = state.connections.first(where: { $0.id == connectionID }),
            connection.statusScope.isValid
        else { return .failure(.permissionDenied) }

        if request.operation == LocalAPIOperation.agentContext.rawValue {
            guard let grant = connection.contextGrant,
                request.paneID == grant.paneID, request.targetVersion == grant.targetVersion,
                request.source != .terminalHistory || grant.allowTerminalHistory
            else { return .failure(.permissionDenied) }
        }

        let candidate = Self.verifier(
            credential: credential,
            profile: state.profile,
            installationID: state.installationID,
            connectionID: connectionID
        )
        guard constantTimeEqual(candidate, connection.credentialVerifier) else {
            return .failure(.permissionDenied)
        }

        let lease = LocalAPIAuthorizationLease(
            connectionID: connectionID,
            globalRevision: state.globalRevision,
            connectionRevision: connection.revision,
            statusScope: connection.statusScope,
            contextGrant: connection.contextGrant
        )
        guard expected == nil || expected == lease else { return .failure(.permissionDenied) }
        return .success(lease)
    }

    private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

@MainActor
@Observable
public final class LocalAPIAccessStore {
    public private(set) var state: LocalAPIAccessState
    public private(set) var loadFailure: LocalAPIAccessFailure?
    public private(set) var persistenceFailureMessage: String?
    public private(set) var ownsAuthority = false
    public let runtimeAuthority: LocalAPIRuntimeAuthority

    @ObservationIgnored private let directoryURL: URL
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private var authorityLockFD: Int32 = -1
    @ObservationIgnored private var invalidateRequests: @Sendable (UUID?) -> Void = { _ in }

    public init(
        profile: String,
        supportDirectoryURL: URL,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        directoryURL = supportDirectoryURL.appending(path: "LocalAPI", directoryHint: .isDirectory)
        fileURL = directoryURL.appending(path: "access.json")
        let empty = LocalAPIAccessState(profile: profile)

        guard LocalAPIProfile.isValid(profile),
            let directory = fileManager.validatedOwnerOnlyDirectory(at: directoryURL, createIfMissing: true),
            let lockFD = Self.acquireAuthorityLock(in: directory)
        else {
            state = empty
            loadFailure = .authorityUnavailable
            runtimeAuthority = LocalAPIRuntimeAuthority(state: empty)
            return
        }

        authorityLockFD = lockFD
        ownsAuthority = true
        let loadedState: LocalAPIAccessState
        do {
            loadedState = try Self.loadState(at: fileURL, expectedProfile: profile, fileManager: fileManager) ?? empty
        } catch {
            loadedState = empty
            loadFailure = .preservedInvalidState
        }
        state = loadedState
        runtimeAuthority = LocalAPIRuntimeAuthority(state: loadedState)
    }

    deinit {
        if authorityLockFD >= 0 { close(authorityLockFD) }
    }

    public func setInvalidationHandler(_ handler: @escaping @Sendable (UUID?) -> Void) {
        invalidateRequests = handler
    }

    public func relinquishAuthority() {
        guard ownsAuthority else { return }
        ownsAuthority = false
        var denied = state
        denied.globallyEnabled = false
        denied.globalRevision = UUID()
        runtimeAuthority.replace(with: denied)
        invalidateRequests(nil)
        if authorityLockFD >= 0 {
            close(authorityLockFD)
            authorityLockFD = -1
        }
        loadFailure = .authorityUnavailable
    }

    public func prepareRegistration(label rawLabel: String, statusScope: LocalAPITargetScope) throws -> LocalAPIPendingRegistration {
        try requireWritableAuthority()
        let label = UnicodeHygiene.sanitize(rawLabel, maxLength: 80, stripInvisibleRoutingScalars: true)
        guard !label.isEmpty else { throw LocalAPIAccessFailure.invalidLabel }
        guard statusScope.isValid else { throw LocalAPIAccessFailure.invalidScope }
        let credential: Data
        do {
            credential = try LocalAPICredentialKeychain.generate()
        } catch {
            throw LocalAPIAccessFailure.credentialGenerationFailed
        }
        let connectionID = UUID()
        return LocalAPIPendingRegistration(
            connection: LocalAPIConnectionGrant(
                id: connectionID,
                label: label,
                createdAt: Date(),
                credentialVerifier: LocalAPIRuntimeAuthority.verifier(
                    credential: credential,
                    profile: state.profile,
                    installationID: state.installationID,
                    connectionID: connectionID
                ),
                revision: UUID(),
                statusScope: statusScope
            ),
            credential: credential
        )
    }

    public func activateRegistration(_ registration: LocalAPIPendingRegistration) throws {
        try requireWritableAuthority()
        guard !state.connections.contains(where: { $0.id == registration.connection.id }) else {
            throw LocalAPIAccessFailure.persistenceFailed
        }
        var candidate = state
        candidate.connections.append(registration.connection)
        candidate.connections.sort { $0.createdAt < $1.createdAt }
        let directorySynced = try persist(candidate)
        publish(candidate)
        recordDurabilityWarningIfNeeded(directorySynced)
    }

    public func setGloballyEnabled(_ enabled: Bool) throws {
        try requireWritableAuthority()
        guard state.globallyEnabled != enabled else { return }
        var candidate = state
        candidate.globallyEnabled = enabled
        candidate.globalRevision = UUID()
        if enabled {
            let directorySynced = try persist(candidate)
            publish(candidate)
            recordDurabilityWarningIfNeeded(directorySynced)
        } else {
            state = candidate
            persistenceFailureMessage = nil
            replaceRuntime(with: candidate, invalidating: .all)
            do {
                let directorySynced = try persist(candidate)
                recordDurabilityWarningIfNeeded(directorySynced)
            } catch {
                persistenceFailureMessage =
                    String(
                        localized: "Access is disabled for this run, but the change could not be saved. Retry before restarting awesoMux."
                    )
                throw error
            }
        }
    }

    public func updateContextGrant(connectionID: UUID, contextGrant: LocalAPIContextGrant?) throws {
        try updateConnection(connectionID: connectionID) { $0.contextGrant = contextGrant }
    }

    public func updateStatusScope(connectionID: UUID, statusScope: LocalAPITargetScope) throws {
        guard statusScope.isValid else { throw LocalAPIAccessFailure.invalidScope }
        try updateConnection(connectionID: connectionID) { $0.statusScope = statusScope }
    }

    private func updateConnection(
        connectionID: UUID,
        change: (inout LocalAPIConnectionGrant) -> Void
    ) throws {
        try requireWritableAuthority()
        guard let index = state.connections.firstIndex(where: { $0.id == connectionID }) else {
            throw LocalAPIAccessFailure.connectionNotFound
        }
        var candidate = state
        change(&candidate.connections[index])
        candidate.connections[index].revision = UUID()

        var denied = candidate
        denied.connections.removeAll { $0.id == connectionID }
        state = candidate
        persistenceFailureMessage = nil
        replaceRuntime(with: denied, invalidating: .connection(connectionID))
        do {
            let directorySynced = try persist(candidate)
            runtimeAuthority.replace(with: candidate)
            recordDurabilityWarningIfNeeded(directorySynced)
        } catch {
            persistenceFailureMessage =
                String(
                    localized:
                        "This connection is denied for this run, but the scope change could not be saved. Retry before restarting awesoMux."
                )
            throw error
        }
    }

    public func revoke(connectionID: UUID) throws {
        try requireWritableAuthority()
        guard state.connections.contains(where: { $0.id == connectionID }) else {
            throw LocalAPIAccessFailure.connectionNotFound
        }
        var candidate = state
        candidate.connections.removeAll { $0.id == connectionID }
        state = candidate
        persistenceFailureMessage = nil
        replaceRuntime(with: candidate, invalidating: .connection(connectionID))
        do {
            let directorySynced = try persist(candidate)
            recordDurabilityWarningIfNeeded(directorySynced)
        } catch {
            persistenceFailureMessage =
                String(
                    localized:
                        "This connection is denied for this run, but revocation could not be saved. Retry before restarting awesoMux."
                )
            throw error
        }
    }

    public func retryPersistence() throws {
        try requireWritableAuthority()
        let directorySynced = try persist(state)
        runtimeAuthority.replace(with: state)
        persistenceFailureMessage = nil
        recordDurabilityWarningIfNeeded(directorySynced)
    }

    private enum Invalidation {
        case none
        case all
        case connection(UUID)
    }

    private func publish(_ candidate: LocalAPIAccessState, invalidating: Invalidation = .none) {
        state = candidate
        persistenceFailureMessage = nil
        replaceRuntime(with: candidate, invalidating: invalidating)
    }

    private func replaceRuntime(with candidate: LocalAPIAccessState, invalidating: Invalidation) {
        runtimeAuthority.replace(with: candidate)
        switch invalidating {
        case .none:
            break
        case .all:
            invalidateRequests(nil)
        case .connection(let connectionID):
            invalidateRequests(connectionID)
        }
    }

    private func requireWritableAuthority() throws {
        guard ownsAuthority else { throw LocalAPIAccessFailure.authorityUnavailable }
        guard loadFailure == nil else { throw LocalAPIAccessFailure.preservedInvalidState }
    }

    private func recordDurabilityWarningIfNeeded(_ directorySynced: Bool) {
        guard !directorySynced else { return }
        persistenceFailureMessage =
            String(
                localized:
                    "Access changes are active and saved, but awesoMux could not confirm directory durability. Retry Save before restarting."
            )
    }

    private func persist(_ candidate: LocalAPIAccessState) throws -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(candidate)
            guard data.count <= Self.maximumStateBytes else { throw LocalAPIAccessFailure.persistenceFailed }
            let directoryFD = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryFD >= 0 else { throw LocalAPIAccessFailure.persistenceFailed }
            defer { close(directoryFD) }
            try fileManager.writeOwnerOnlyFile(at: fileURL, contents: data)
            return fsync(directoryFD) == 0
        } catch let error as LocalAPIAccessFailure {
            throw error
        } catch {
            throw LocalAPIAccessFailure.persistenceFailed
        }
    }

    private static let maximumStateBytes = 256 * 1024

    private static func loadState(
        at url: URL,
        expectedProfile: String,
        fileManager: FileManager
    ) throws -> LocalAPIAccessState? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let contents = try SecureFileReader.read(
            at: url,
            maximumBytes: maximumStateBytes,
            symlinkPolicy: .rejectFinalComponent
        )
        guard let mode = (try fileManager.attributesOfItem(atPath: url.path))[.posixPermissions] as? NSNumber,
            mode.intValue & 0o777 == 0o600,
            strictShapeIsValid(contents.data)
        else { throw LocalAPIAccessFailure.preservedInvalidState }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LocalAPIAccessState.self, from: contents.data)
        guard decoded.schemaVersion == LocalAPIAccessState.schemaVersion,
            decoded.profile == expectedProfile,
            Set(decoded.connections.map(\.id)).count == decoded.connections.count,
            decoded.connections.allSatisfy({ connection in
                connection.credentialVerifier.count == SHA256.byteCount
                    && connection.statusScope.isValid
                    && UnicodeHygiene.sanitize(
                        connection.label,
                        maxLength: 80,
                        stripInvisibleRoutingScalars: true
                    ) == connection.label
            })
        else { throw LocalAPIAccessFailure.preservedInvalidState }
        return decoded
    }

    private static func strictShapeIsValid(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(root.keys) == Set(["schemaVersion", "profile", "installationID", "globallyEnabled", "globalRevision", "connections"]),
            let connections = root["connections"] as? [[String: Any]],
            connections.allSatisfy({
                Set($0.keys).isSubset(of: ["id", "label", "createdAt", "credentialVerifier", "revision", "statusScope", "contextGrant"])
                    && scopeShapeIsValid($0["statusScope"])
                    && contextShapeIsValid($0["contextGrant"])
            })
        else { return false }
        return true
    }

    private static func contextShapeIsValid(_ value: Any?) -> Bool {
        guard let value else { return true }
        guard let grant = value as? [String: Any] else { return false }
        return Set(grant.keys) == ["paneID", "targetVersion", "allowTerminalHistory"]
    }

    private static func scopeShapeIsValid(_ value: Any?) -> Bool {
        guard let scope = value as? [String: Any], scope.count == 1,
            let kind = scope.keys.first,
            let payload = scope[kind] as? [String: Any]
        else { return false }
        switch kind {
        case "exactTarget":
            return Set(payload.keys) == Set(["paneID", "targetVersion"])
        case "persistentPanes", "persistentWorkspaces":
            return Set(payload.keys) == ["_0"] && payload["_0"] is [String]
        default:
            return false
        }
    }

    private static func acquireAuthorityLock(in directoryURL: URL) -> Int32? {
        let lockURL = directoryURL.appending(path: "authority.lock")
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        var status = stat()
        guard fstat(fd, &status) == 0,
            status.st_uid == geteuid(),
            status.st_mode & S_IFMT == S_IFREG,
            status.st_mode & 0o777 == 0o600,
            status.st_nlink == 1,
            flock(fd, LOCK_EX | LOCK_NB) == 0
        else {
            close(fd)
            return nil
        }
        return fd
    }
}
