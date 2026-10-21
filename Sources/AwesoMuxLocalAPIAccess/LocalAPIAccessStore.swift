import AwesoMuxCompanionProtocol
import AwesoMuxConfig
import AwesoMuxLocalAPI
import AwesoMuxLocalAPICredentials
import CryptoKit
import CoreFoundation
import Darwin
import Foundation
import Observation
import SecureFileIO
import UnicodeHygiene

public enum LocalAPIConnectionKind: String, Codable, Sendable {
    case outsideApp
    case companion
}

public enum LocalAPICompanionTransport: String, Codable, CaseIterable, Sendable {
    case lan
    case tailscale
}

public struct LocalAPICompanionMetadata: Codable, Equatable, Sendable {
    public let certificateFingerprint: Data
    public let transport: LocalAPICompanionTransport
    public let pairedAt: Date
    public let port: UInt16
    public var paneRenameScope: LocalAPITargetScope?
    public let pairingVersion: Int?
    public var alertPreferences: CompanionAlertPreferences?

    public func allows(_ transport: LocalAPICompanionTransport) -> Bool {
        pairingVersion == 2 || self.transport == transport
    }
    public var terminalPreviewAllowed: Bool

    public init(
        certificateFingerprint: Data,
        transport: LocalAPICompanionTransport,
        pairedAt: Date,
        port: UInt16,
        paneRenameScope: LocalAPITargetScope? = nil,
        pairingVersion: Int? = nil,
        terminalPreviewAllowed: Bool = false,
        alertPreferences: CompanionAlertPreferences? = nil
    ) {
        self.certificateFingerprint = certificateFingerprint
        self.transport = transport
        self.pairedAt = pairedAt
        self.port = port
        self.paneRenameScope = paneRenameScope
        self.pairingVersion = pairingVersion
        self.terminalPreviewAllowed = terminalPreviewAllowed
        self.alertPreferences = alertPreferences
    }

    private enum CodingKeys: String, CodingKey {
        case certificateFingerprint, transport, pairedAt, port, paneRenameScope, pairingVersion, terminalPreviewAllowed, alertPreferences
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        certificateFingerprint = try values.decode(Data.self, forKey: .certificateFingerprint)
        transport = try values.decode(LocalAPICompanionTransport.self, forKey: .transport)
        pairedAt = try values.decode(Date.self, forKey: .pairedAt)
        port = try values.decode(UInt16.self, forKey: .port)
        paneRenameScope = try values.decodeIfPresent(LocalAPITargetScope.self, forKey: .paneRenameScope)
        pairingVersion = try values.decodeIfPresent(Int.self, forKey: .pairingVersion)
        terminalPreviewAllowed = try values.decodeIfPresent(Bool.self, forKey: .terminalPreviewAllowed) ?? false
        alertPreferences = try values.decodeIfPresent(CompanionAlertPreferences.self, forKey: .alertPreferences)
    }

}

public struct LocalAPIConnectionGrant: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var label: String
    public let createdAt: Date
    public var credentialVerifier: Data
    public var revision: UUID
    public var statusScope: LocalAPITargetScope
    public var contextGrant: LocalAPIContextGrant?
    public var kind: LocalAPIConnectionKind
    public var companion: LocalAPICompanionMetadata?

    public init(
        id: UUID,
        label: String,
        createdAt: Date,
        credentialVerifier: Data,
        revision: UUID,
        statusScope: LocalAPITargetScope,
        contextGrant: LocalAPIContextGrant? = nil,
        kind: LocalAPIConnectionKind = .outsideApp,
        companion: LocalAPICompanionMetadata? = nil
    ) {
        self.id = id
        self.label = label
        self.createdAt = createdAt
        self.credentialVerifier = credentialVerifier
        self.revision = revision
        self.statusScope = statusScope
        self.contextGrant = contextGrant
        self.kind = kind
        self.companion = companion
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, createdAt, credentialVerifier, revision, statusScope, contextGrant, kind, companion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        credentialVerifier = try container.decodeIfPresent(Data.self, forKey: .credentialVerifier) ?? Data()
        revision = try container.decode(UUID.self, forKey: .revision)
        statusScope = try container.decode(LocalAPITargetScope.self, forKey: .statusScope)
        contextGrant = try container.decodeIfPresent(LocalAPIContextGrant.self, forKey: .contextGrant)
        kind = try container.decodeIfPresent(LocalAPIConnectionKind.self, forKey: .kind) ?? .outsideApp
        companion = try container.decodeIfPresent(LocalAPICompanionMetadata.self, forKey: .companion)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(createdAt, forKey: .createdAt)
        if !credentialVerifier.isEmpty { try container.encode(credentialVerifier, forKey: .credentialVerifier) }
        try container.encode(revision, forKey: .revision)
        try container.encode(statusScope, forKey: .statusScope)
        try container.encodeIfPresent(contextGrant, forKey: .contextGrant)
        if kind != .outsideApp { try container.encode(kind, forKey: .kind) }
        try container.encodeIfPresent(companion, forKey: .companion)
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
                        connection.kind == .outsideApp,
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

    public func authorizeCompanion(
        connectionID: UUID,
        certificateFingerprint: Data,
        operation: LocalAPIOperation,
        matching expected: LocalAPIAuthorizationLease? = nil
    ) -> Result<LocalAPIAuthorizationLease, LocalAPIError> {
        lock.withLock {
            guard operation == .connectionStatus || operation == .listAgents || operation == .attentionEvents,
                let connection = state.connections.first(where: { $0.id == connectionID }),
                connection.kind == .companion,
                connection.statusScope == .allWorkspaces,
                connection.contextGrant == nil,
                let metadata = connection.companion,
                constantTimeEqual(certificateFingerprint, metadata.certificateFingerprint)
            else { return .failure(.permissionDenied) }
            let lease = LocalAPIAuthorizationLease(
                connectionID: connection.id,
                // Companion authorization is intentionally independent from the
                // Outside app access global switch and its revision.
                globalRevision: connection.revision,
                connectionRevision: connection.revision,
                statusScope: connection.statusScope,
                contextGrant: nil,
                paneRenameScope: metadata.paneRenameScope,
                terminalPreviewAllowed: metadata.terminalPreviewAllowed,
                companionAlertPreferences: metadata.alertPreferences ?? CompanionAlertPreferences()
            )
            guard expected == nil || expected == lease else { return .failure(.permissionDenied) }
            return .success(lease)
        }
    }

    public func commitCompanion(
        connectionID: UUID,
        certificateFingerprint: Data,
        lease: LocalAPIAuthorizationLease,
        body: @Sendable () throws -> Int
    ) throws -> Int {
        try lock.withLock {
            guard connectionID == lease.connectionID,
                let connection = state.connections.first(where: { $0.id == connectionID }),
                connection.kind == .companion,
                connection.revision == lease.connectionRevision,
                connection.statusScope == lease.statusScope,
                connection.contextGrant == nil,
                let metadata = connection.companion,
                metadata.paneRenameScope == lease.paneRenameScope,
                metadata.terminalPreviewAllowed == lease.terminalPreviewAllowed,
                (metadata.alertPreferences ?? CompanionAlertPreferences()) == lease.companionAlertPreferences,
                constantTimeEqual(certificateFingerprint, metadata.certificateFingerprint)
            else { throw LocalAPIError.permissionDenied }
            return try body()
        }
    }

    /// Hold the authority lock across the synchronous native mutation so a
    /// concurrent policy replacement cannot race the final lease check.
    public func performCompanionPaneRename(
        certificateFingerprint: Data,
        lease: LocalAPIAuthorizationLease,
        body: () throws -> Void
    ) throws {
        try lock.withLock {
            guard let connection = state.connections.first(where: { $0.id == lease.connectionID }),
                connection.kind == .companion,
                connection.revision == lease.connectionRevision,
                lease.globalRevision == connection.revision,
                connection.statusScope == lease.statusScope,
                connection.contextGrant == nil, lease.contextGrant == nil,
                let metadata = connection.companion,
                let scope = metadata.paneRenameScope, scope.isValid,
                scope == lease.paneRenameScope,
                constantTimeEqual(certificateFingerprint, metadata.certificateFingerprint)
            else { throw LocalAPIError.permissionDenied }
            try body()
        }
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
            connection.kind == .outsideApp,
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
    @ObservationIgnored private var invalidateCompanionRequests: @Sendable (UUID?) -> Void = { _ in }

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

    public func setCompanionInvalidationHandler(_ handler: @escaping @Sendable (UUID?) -> Void) {
        invalidateCompanionRequests = handler
    }

    public func relinquishAuthority() {
        guard ownsAuthority else { return }
        ownsAuthority = false
        var denied = state
        denied.globallyEnabled = false
        denied.globalRevision = UUID()
        denied.connections.removeAll { $0.kind == .companion }
        runtimeAuthority.replace(with: denied)
        invalidateRequests(nil)
        invalidateCompanionRequests(nil)
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

    @discardableResult
    public func registerCompanion(
        phoneName rawPhoneName: String,
        certificateFingerprint: Data,
        transport: LocalAPICompanionTransport,
        port: UInt16,
        pairingVersion: Int? = nil,
        pairedAt: Date = Date(),
        terminalPreviewAllowed: Bool = false
    ) throws -> LocalAPIConnectionGrant {
        try requireWritableAuthority()
        let phoneName = UnicodeHygiene.sanitize(rawPhoneName, maxLength: 80, stripInvisibleRoutingScalars: true)
        guard !phoneName.isEmpty else { throw LocalAPIAccessFailure.invalidLabel }
        guard port != 0, pairingVersion == nil || pairingVersion == 2 else { throw LocalAPIAccessFailure.persistenceFailed }
        guard state.connections.filter({ $0.kind == .companion }).allSatisfy({ $0.companion?.port == port }) else {
            throw LocalAPIAccessFailure.persistenceFailed
        }
        guard certificateFingerprint.count == SHA256.byteCount else { throw LocalAPIAccessFailure.persistenceFailed }
        let connection = LocalAPIConnectionGrant(
            id: UUID(),
            label: phoneName,
            createdAt: pairedAt,
            credentialVerifier: Data(),
            revision: UUID(),
            statusScope: .allWorkspaces,
            kind: .companion,
            companion: LocalAPICompanionMetadata(
                certificateFingerprint: certificateFingerprint,
                transport: transport,
                pairedAt: pairedAt,
                port: port,
                pairingVersion: pairingVersion,
                terminalPreviewAllowed: terminalPreviewAllowed
            )
        )
        var candidate = state
        let replaced = candidate.connections.first { $0.companion?.certificateFingerprint == certificateFingerprint }
        candidate.connections.removeAll { $0.companion?.certificateFingerprint == certificateFingerprint }
        candidate.connections.append(connection)
        candidate.connections.sort { $0.createdAt < $1.createdAt }
        let directorySynced = try persist(candidate)
        publish(candidate, invalidating: replaced.map { .connection($0.id) } ?? .none)
        recordDurabilityWarningIfNeeded(directorySynced)
        return connection
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

    public func updateCompanionPaneRenameScope(connectionID: UUID, scope: LocalAPITargetScope?) throws {
        guard scope?.isValid != false else { throw LocalAPIAccessFailure.invalidScope }
        try requireWritableAuthority()
        guard let connection = state.connections.first(where: { $0.id == connectionID }),
            connection.kind == .companion, let metadata = connection.companion
        else { throw LocalAPIAccessFailure.connectionNotFound }
        guard metadata.paneRenameScope != scope || persistenceFailureMessage != nil else { return }
        try updateConnection(connectionID: connectionID, kind: .companion) {
            $0.companion?.paneRenameScope = scope
        }
    }

    public func updateCompanionTerminalPreviewAllowed(connectionID: UUID, allowed: Bool) throws {
        try requireWritableAuthority()
        guard let connection = state.connections.first(where: { $0.id == connectionID }),
            connection.kind == .companion, let metadata = connection.companion
        else { throw LocalAPIAccessFailure.connectionNotFound }
        guard metadata.terminalPreviewAllowed != allowed || persistenceFailureMessage != nil else { return }
        try updateConnection(connectionID: connectionID, kind: .companion) {
            $0.companion?.terminalPreviewAllowed = allowed
        }
    }

    /// Revalidate on MainActor immediately before mutation, then retain the
    /// refreshed lease for every acknowledgement write.
    public func setCompanionTerminalPreviewAllowed(
        connectionID: UUID, allowed: Bool, certificateFingerprint: Data,
        expectedLease: LocalAPIAuthorizationLease
    ) throws -> LocalAPIAuthorizationLease {
        _ = try runtimeAuthority.authorizeCompanion(
            connectionID: connectionID, certificateFingerprint: certificateFingerprint,
            operation: .connectionStatus, matching: expectedLease
        ).get()
        try updateCompanionTerminalPreviewAllowed(connectionID: connectionID, allowed: allowed)
        return try runtimeAuthority.authorizeCompanion(
            connectionID: connectionID, certificateFingerprint: certificateFingerprint,
            operation: .connectionStatus
        ).get()
    }

    public func updateCompanionAlertPreferences(connectionID: UUID, preferences: CompanionAlertPreferences) throws {
        try requireWritableAuthority()
        guard let index = state.connections.firstIndex(where: { $0.id == connectionID }),
            state.connections[index].kind == .companion,
            let metadata = state.connections[index].companion
        else { throw LocalAPIAccessFailure.connectionNotFound }
        guard (metadata.alertPreferences ?? CompanionAlertPreferences()) != preferences else { return }
        var candidate = state
        candidate.connections[index].companion?.alertPreferences = preferences
        candidate.connections[index].revision = UUID()
        let directorySynced = try persist(candidate)
        publish(candidate, invalidating: .connection(connectionID))
        recordDurabilityWarningIfNeeded(directorySynced)
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
        kind: LocalAPIConnectionKind = .outsideApp,
        change: (inout LocalAPIConnectionGrant) -> Void
    ) throws {
        try requireWritableAuthority()
        guard let index = state.connections.firstIndex(where: { $0.id == connectionID }) else {
            throw LocalAPIAccessFailure.connectionNotFound
        }
        guard state.connections[index].kind == kind else {
            throw LocalAPIAccessFailure.invalidScope
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
            invalidateCompanionRequests(connectionID)
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
                ((connection.kind == .outsideApp
                    && connection.credentialVerifier.count == SHA256.byteCount
                    && connection.companion == nil)
                    || (connection.kind == .companion
                        && connection.credentialVerifier.isEmpty
                        && connection.statusScope == .allWorkspaces
                        && connection.contextGrant == nil
                        && connection.companion?.certificateFingerprint.count == SHA256.byteCount
                        && connection.companion?.port != 0
                        && connection.companion?.paneRenameScope?.isValid != false))
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
                Set($0.keys).isSubset(
                    of: ["id", "label", "createdAt", "credentialVerifier", "revision", "statusScope", "contextGrant", "kind", "companion"]
                )
                    && scopeShapeIsValid($0["statusScope"])
                    && contextShapeIsValid($0["contextGrant"])
                    && companionShapeIsValid($0["companion"])
            })
        else { return false }
        return true
    }

    private static func contextShapeIsValid(_ value: Any?) -> Bool {
        guard let value else { return true }
        guard let grant = value as? [String: Any] else { return false }
        return Set(grant.keys) == ["paneID", "targetVersion", "allowTerminalHistory"]
    }

    private static func companionShapeIsValid(_ value: Any?) -> Bool {
        guard let value else { return true }
        guard let metadata = value as? [String: Any] else { return false }
        var keys = Set(metadata.keys)
        if let scope = metadata["paneRenameScope"] {
            guard scopeShapeIsValid(scope) else { return false }
            keys.remove("paneRenameScope")
        }
        if let allowed = metadata["terminalPreviewAllowed"] {
            guard let number = allowed as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            keys.remove("terminalPreviewAllowed")
        }
        if let preferences = metadata["alertPreferences"] {
            guard let object = preferences as? [String: Any], Set(object.keys) == ["categories"],
                let categories = object["categories"] as? [String],
                categories.allSatisfy({ CompanionAlertCategory(rawValue: $0) != nil })
            else { return false }
            keys.remove("alertPreferences")
        }
        let legacy: Set<String> = ["certificateFingerprint", "transport", "pairedAt", "port"]
        if keys == legacy { return true }
        return keys == legacy.union(["pairingVersion"]) && (metadata["pairingVersion"] as? Int) == 2
    }

    private static func scopeShapeIsValid(_ value: Any?) -> Bool {
        guard let scope = value as? [String: Any], scope.count == 1,
            let kind = scope.keys.first,
            let payload = scope[kind] as? [String: Any]
        else { return false }
        switch kind {
        case "allWorkspaces":
            return payload.isEmpty
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
