import AppKit
import AwesoMuxCompanionProtocol
import AwesoMuxLocalAPI
import AwesoMuxLocalAPIAccess
import CryptoKit
import Darwin
import Foundation
import Network
import Observation
import Security
import UnicodeHygiene

typealias CompanionDelay = @Sendable (Duration) async throws -> Void

struct CompanionPairingSession: Identifiable, Equatable, Sendable {
    let id: UUID
    let link: String
    let expiresAt: Date
}

struct CompanionApprovalPrompt: Identifiable, Equatable, Sendable {
    let id: UUID
    let phoneName: String
    let words: [String]
}

private struct ClaimedCompanionPairing: Sendable {
    let id: UUID
    let words: [String]
}

enum CompanionPairingResult: Equatable, Sendable {
    case paired
    case denied
    case expired
}

enum CompanionPairingError: Error {
    case noLocalAddress
    case identityUnavailable
    case listenerUnavailable
    case invalidRequest
    case timeout
    case connectionClosed
}

@MainActor
@Observable
final class CompanionPairingCoordinator {
    private(set) var pairingSession: CompanionPairingSession?
    private(set) var pairingResult: CompanionPairingResult?
    private(set) var approvalPrompt: CompanionApprovalPrompt?
    private(set) var boundAddresses: [CompanionNetworkAddress] = []
    private(set) var listenerErrorMessage: String?
    private(set) var lastSeen: [UUID: Date] = [:]

    @ObservationIgnored private let profile: AppRuntimeProfile
    @ObservationIgnored private let accessStore: LocalAPIAccessStore
    @ObservationIgnored private let delay: CompanionDelay
    @ObservationIgnored private var identity: CompanionIdentity?
    @ObservationIgnored private var service: LocalAPIService?
    @ObservationIgnored private var servers: [CompanionNetworkServer] = []
    @ObservationIgnored private var stablePort: UInt16?
    @ObservationIgnored private var secret: Data?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var pendingApproval: PendingApproval?
    @ObservationIgnored private var pairingGeneration: UUID?
    @ObservationIgnored private var listenerGeneration = UUID()
    @ObservationIgnored private var listenerStartTask: Task<Void, Error>?
    @ObservationIgnored private var listenerStartID: UUID?
    @ObservationIgnored private var listenerLifecycle = UUID()
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?

    init(
        profile: AppRuntimeProfile,
        accessStore: LocalAPIAccessStore,
        delay: @escaping CompanionDelay = { try await ContinuousClock().sleep(for: $0) }
    ) {
        self.profile = profile
        self.accessStore = accessStore
        self.delay = delay
    }

    var pairedPhones: [LocalAPIConnectionGrant] {
        accessStore.state.connections.filter { $0.kind == .companion }
    }

    private var currentRoutes: CompanionRoutes? {
        guard let port = stablePort, !boundAddresses.isEmpty else { return nil }
        return CompanionRoutes(
            p: port,
            lan: boundAddresses.first { $0.transport == .lan }?.host,
            tailscale: boundAddresses.first { $0.transport == .tailscale }?.host
        )
    }

    var currentPairingLink: String? { boundAddresses.isEmpty ? nil : pairingSession?.link }

    var persistenceFailureMessage: String? { accessStore.persistenceFailureMessage }

    func configure(service: LocalAPIService) {
        guard self.service == nil else { return }
        self.service = service
        reconcileDecisionWorkspaces()
        accessStore.setCompanionInvalidationHandler { [weak self] connectionID in
            Task { @MainActor in self?.invalidateConnections(connectionID: connectionID) }
        }
        if let mostRecent = pairedPhones.last, let metadata = mostRecent.companion {
            startWatchingNetwork()
            Task { await startListener(preferredPort: metadata.port) }
        }
        #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            if case .development = profile,
                let linkPath = environment["AWESOMUX_COMPANION_E2E_LINK_FILE"], !linkPath.isEmpty
            {
                Task {
                    do {
                        if environment["AWESOMUX_COMPANION_E2E_RESET_IDENTITY"] == "1" {
                            guard pairedPhones.isEmpty else { throw CompanionPairingError.identityUnavailable }
                            try CompanionIdentityStore.reset(profile: profile.environmentValue)
                            identity = nil
                        }
                        let session = try await beginPairing()
                        try Data((session.link + "\n").utf8).write(to: URL(fileURLWithPath: linkPath), options: .atomic)
                    } catch {
                        listenerErrorMessage = String(localized: "Companion pairing could not start.")
                    }
                }
            }
        #endif
    }

    func beginPairing() async throws -> CompanionPairingSession {
        cancelPairing()
        pairingResult = nil
        let generation = UUID()
        pairingGeneration = generation
        defer {
            if pairingGeneration == generation, pairingSession == nil {
                pairingGeneration = nil
                stopListenerIfIdle()
            }
        }
        startWatchingNetwork()
        let loadedIdentity: CompanionIdentity
        do {
            loadedIdentity = try identity ?? CompanionIdentityStore.loadOrCreate(profile: profile.environmentValue)
        } catch {
            throw CompanionPairingError.identityUnavailable
        }
        identity = loadedIdentity
        let preferredPort = pairedPhones.last?.companion?.port
        try await replaceListeners(identity: loadedIdentity, preferredPort: preferredPort)
        guard pairingGeneration == generation, !Task.isCancelled else {
            throw CompanionPairingError.connectionClosed
        }
        guard let routes = currentRoutes else { throw CompanionPairingError.listenerUnavailable }
        var generatedSecret = Data(count: LocalAPICredential.byteCount)
        guard
            generatedSecret.withUnsafeMutableBytes({ bytes in
                SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
            }) == errSecSuccess
        else { throw CompanionPairingError.identityUnavailable }
        secret = generatedSecret
        let id = UUID()
        let expiresAt = Date().addingTimeInterval(5 * 60)
        let macName = Host.current().localizedName ?? String(localized: "This Mac")
        let link = try CompanionPairingLinkV2(
            routes: routes,
            macFingerprint: loadedIdentity.fingerprint.companionBase64URL,
            secret: generatedSecret.companionBase64URL,
            macName: macName
        ).string()
        let session = CompanionPairingSession(id: id, link: link, expiresAt: expiresAt)
        pairingSession = session
        servers.forEach { $0.pairingIsOpen = true }
        expiryTask = Task { [weak self] in
            try? await self?.delay(.seconds(5 * 60))
            guard !Task.isCancelled else { return }
            self?.expirePairing(id: id)
        }
        return session
    }

    func cancelPairing() {
        let hadPendingApproval = pendingApproval != nil
        expiryTask?.cancel()
        expiryTask = nil
        secret = nil
        pairingSession = nil
        servers.forEach { $0.pairingIsOpen = false }
        pairingGeneration = nil
        resolveApproval(allowed: false)
        if !hadPendingApproval { stopListenerIfIdle() }
    }

    func allowPendingPhone() { resolveApproval(allowed: true) }

    func denyPendingPhone() {
        guard let id = pendingApproval?.id else { return }
        denyPendingPhone(id: id)
    }

    func clearListenerError() { listenerErrorMessage = nil }

    func retryPersistence() throws { try accessStore.retryPersistence() }

    func setPaneRenameAllowed(_ allowed: Bool, for phone: LocalAPIConnectionGrant) throws {
        try accessStore.updateCompanionPaneRenameScope(
            connectionID: phone.id, scope: allowed ? phone.statusScope : nil)
    }

    func reconcileDecisionWorkspaces() {
        guard let service else { return }
        let phones = pairedPhones.filter { $0.companion?.decideWorkspaceIDs != nil }
        guard !phones.isEmpty else { return }
        let live = Set(service.companionDecisionWorkspaces.map(\.id))
        for phone in phones {
            guard let previous = phone.companion?.decideWorkspaceIDs else { continue }
            let retained = previous.filter { live.contains($0) }
            guard retained != previous else { continue }
            do {
                try accessStore.updateCompanionDecideWorkspaces(connectionID: phone.id, workspaceIDs: retained.isEmpty ? nil : retained)
            } catch {
                listenerErrorMessage = String(
                    localized: "Could not save decision access.",
                    comment: "Error shown when saving a paired phone’s workspace decision permission fails.")
            }
        }
    }

    var decisionWorkspaces: [(id: UUID, name: String)] { service?.companionDecisionWorkspaces ?? [] }

    func setDecisionWorkspace(_ workspaceID: UUID, allowed: Bool, for phoneID: UUID) throws {
        guard decisionWorkspaces.contains(where: { $0.id == workspaceID }) else { throw LocalAPIError.permissionDenied }
        var ids = pairedPhones.first { $0.id == phoneID }?.companion?.decideWorkspaceIDs ?? []
        ids.removeAll { $0 == workspaceID }
        if allowed { ids.append(workspaceID) }
        try accessStore.updateCompanionDecideWorkspaces(connectionID: phoneID, workspaceIDs: ids.isEmpty ? nil : ids)
    }

    func updateTerminalPreviewAllowed(_ allowed: Bool, for connectionID: UUID) throws {
        try accessStore.updateCompanionTerminalPreviewAllowed(connectionID: connectionID, allowed: allowed)
    }

    func unpair(_ connection: LocalAPIConnectionGrant) throws {
        defer {
            lastSeen.removeValue(forKey: connection.id)
            stopListenerIfIdle()
        }
        try accessStore.revoke(connectionID: connection.id)
    }

    func stop() {
        cancelPairing()
        stopWatchingNetwork()
        listenerStartTask?.cancel()
        listenerStartTask = nil
        listenerStartID = nil
        listenerLifecycle = UUID()
        listenerGeneration = UUID()
        servers.forEach { $0.stop() }
        servers = []
        boundAddresses = []
        stablePort = nil
    }

    private func expirePairing(id: UUID) {
        guard pairingSession?.id == id else { return }
        endPairing(result: .expired)
        stopListenerIfIdle()
    }

    private func startWatchingNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        let lifecycle = listenerLifecycle
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.listenerLifecycle == lifecycle, self.pathMonitor != nil else { return }
                await self.restoreListener()
            }
        }
        monitor.start(queue: DispatchQueue(label: "awesomux.companion.path", qos: .utility))
    }

    private func stopWatchingNetwork() {
        pathMonitor?.cancel()
        pathMonitor = nil
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    private func restoreListener() async {
        guard pathMonitor != nil, pairingSession != nil || pairingGeneration != nil || !pairedPhones.isEmpty else { return }
        await startListener(preferredPort: pairedPhones.last?.companion?.port ?? stablePort)
    }

    private func scheduleListenerRecovery() {
        guard pathMonitor != nil, pairingSession != nil || pairingGeneration != nil || !pairedPhones.isEmpty,
            recoveryTask == nil
        else { return }
        recoveryTask = Task { [weak self, delay] in
            try? await delay(.seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.recoveryTask = nil
            await self.restoreListener()
        }
    }

    private func startListener(preferredPort: UInt16?) async {
        guard pathMonitor != nil else { return }
        let lifecycle = listenerLifecycle
        do {
            let loadedIdentity = try identity ?? CompanionIdentityStore.loadOrCreate(profile: profile.environmentValue)
            identity = loadedIdentity
            try await replaceListeners(identity: loadedIdentity, preferredPort: preferredPort)
        } catch {
            guard listenerLifecycle == lifecycle else { return }
            listenerErrorMessage = String(localized: "Companion is not listening. Open Settings and try pairing again.")
            scheduleListenerRecovery()
        }
    }

    private func replaceListeners(
        identity: CompanionIdentity,
        preferredPort: UInt16?
    ) async throws {
        let lifecycle = listenerLifecycle
        let pending = listenerStartTask
        let requestID = UUID()
        let task = Task {
            if let pending { _ = await pending.result }
            guard listenerLifecycle == lifecycle, !Task.isCancelled else {
                throw CompanionPairingError.connectionClosed
            }
            try await reconcileListeners(identity: identity, preferredPort: preferredPort)
        }
        listenerStartTask = task
        listenerStartID = requestID
        defer {
            if listenerStartID == requestID {
                listenerStartTask = nil
                listenerStartID = nil
            }
        }
        try await task.value
    }

    private func reconcileListeners(identity: CompanionIdentity, preferredPort: UInt16?) async throws {
        let addresses = CompanionNetworkAddress.selected(CompanionNetworkAddress.current())
        stablePort = preferredPort ?? stablePort
        for server in servers where !addresses.contains(server.address) {
            server.stop()
        }
        servers.removeAll { !addresses.contains($0.address) }
        updateBoundAddresses()
        guard !addresses.isEmpty else { throw CompanionPairingError.noLocalAddress }
        defer { stopListenerIfIdle() }
        let lifecycle = listenerLifecycle
        for address in addresses where !servers.contains(where: { $0.address == address }) {
            do {
                try await startReplacementListener(identity: identity, address: address, preferredPort: stablePort)
            } catch {
                guard listenerLifecycle == lifecycle else { throw CompanionPairingError.connectionClosed }
                scheduleListenerRecovery()
            }
        }
        updateBoundAddresses()
        guard !servers.isEmpty else { throw CompanionPairingError.listenerUnavailable }
        listenerErrorMessage = nil
    }

    private func updateBoundAddresses() {
        boundAddresses = servers.map(\.address)
        guard let session = pairingSession, let routes = currentRoutes else { return }
        do {
            let previous = try CompanionPairingLinkV2(session.link)
            let link = try CompanionPairingLinkV2(
                routes: routes, macFingerprint: previous.macFingerprint,
                secret: previous.secret, macName: previous.macName
            ).string()
            pairingSession = CompanionPairingSession(id: session.id, link: link, expiresAt: session.expiresAt)
        } catch {
            endPairing(result: .denied)
        }
    }

    private func startReplacementListener(
        identity: CompanionIdentity,
        address: CompanionNetworkAddress,
        preferredPort: UInt16?
    ) async throws {
        guard let service else { throw CompanionPairingError.listenerUnavailable }
        let generation = listenerGeneration
        let newServer = CompanionNetworkServer(
            identity: identity,
            address: address,
            preferredPort: preferredPort,
            profile: profile.environmentValue,
            instanceID: service.instanceID,
            authority: accessStore.runtimeAuthority,
            delay: delay,
            pairedConnections: { [weak accessStore] in
                accessStore?.state.connections.filter { $0.kind == .companion } ?? []
            },
            claimSecret: { [weak self] candidate, phoneSPKI in
                guard let self else { return nil }
                return self.claimSecret(candidate, phoneSPKI: phoneSPKI)
            },
            requestApproval: { [weak self] approvalID, phoneName, words in
                guard let self else { return false }
                return await self.requestApproval(id: approvalID, phoneName: phoneName, words: words)
            },
            cancelApproval: { [weak self] approvalID in self?.denyPendingPhone(id: approvalID) },
            abortPairing: { [weak self] pairingID in self?.abortSpentPairing(id: pairingID) },
            register: { [weak self] pairingID, phoneName, fingerprint, transport, port in
                guard let self else { throw CompanionPairingError.connectionClosed }
                guard self.pairingSession?.id == pairingID else { throw CompanionPairingError.connectionClosed }
                let grant = try self.accessStore.registerCompanion(
                    phoneName: phoneName,
                    certificateFingerprint: fingerprint,
                    transport: transport,
                    port: port,
                    pairingVersion: 2,
                    terminalPreviewAllowed: true
                )
                #if DEBUG
                    if let workspaceID = service.decisionFixtureWorkspaceID {
                        try self.accessStore.updateCompanionDecideWorkspaces(connectionID: grant.id, workspaceIDs: [workspaceID])
                    }
                #endif
                self.servers.forEach { $0.refreshAuthorization() }
                self.finishPairing(id: pairingID)
                return grant
            },
            revoke: { [weak self] connectionID in
                guard let self else { throw CompanionPairingError.connectionClosed }
                defer { self.lastSeen.removeValue(forKey: connectionID) }
                try self.accessStore.revoke(connectionID: connectionID)
            },
            setAlertPreferences: { [weak accessStore] connectionID, preferences in
                guard let accessStore else { throw LocalAPIError.appUnavailable }
                try accessStore.updateCompanionAlertPreferences(connectionID: connectionID, preferences: preferences)
            },
            renamePane: { request, lease, fingerprint, deadline in
                try service.renameCompanionPane(
                    request: request, lease: lease, certificateFingerprint: fingerprint, deadline: deadline)
            },
            setTerminalPreview: { [weak self] connectionID, fingerprint, lease, allowed in
                guard let self else { throw LocalAPIError.appUnavailable }
                return try self.accessStore.setCompanionTerminalPreviewAllowed(
                    connectionID: connectionID, allowed: allowed,
                    certificateFingerprint: fingerprint, expectedLease: lease
                )
            },
            capture: { request, lease, routes in
                await service.companionResponse(request: request, lease: lease, routes: routes)
            },
            routes: { [weak self] in self?.currentRoutes },
            markActivity: { [weak self] in self?.service?.recordAuthenticatedCompanionActivity() },
            markSeen: { [weak self] connectionID in self?.lastSeen[connectionID] = Date() },
            connectionFinished: { [weak self] in self?.stopListenerIfIdle() },
            decisions: { [weak self] answer, lease, fingerprint, requestID in
                guard let self else { throw LocalAPIError.appUnavailable }
                let name = self.pairedPhones.first { $0.id == lease.connectionID }?.label ?? "iPhone"
                return try service.companionDecisions(
                    answer: answer, lease: lease, fingerprint: fingerprint,
                    authority: self.accessStore.runtimeAuthority, deviceName: name, requestID: requestID)
            },
            listenerFailed: { [weak self] in
                guard let self, self.listenerGeneration == generation else { return }
                self.servers.filter { $0.address == address }.forEach { $0.stop() }
                self.servers.removeAll { $0.address == address }
                self.updateBoundAddresses()
                self.scheduleListenerRecovery()
                self.stopListenerIfIdle()
            }
        )
        do {
            try await newServer.start()
        } catch {
            newServer.stop()
            throw error
        }
        guard listenerGeneration == generation, !Task.isCancelled else {
            newServer.stop()
            throw CompanionPairingError.connectionClosed
        }
        newServer.pairingIsOpen = pairingSession != nil
        newServer.refreshAuthorization()
        servers.append(newServer)
        stablePort = newServer.port
        updateBoundAddresses()
        listenerErrorMessage = nil
    }

    private func claimSecret(_ candidate: Data, phoneSPKI: Data) -> ClaimedCompanionPairing? {
        guard let pairingSession, pairingSession.expiresAt > Date(),
            let secret, Self.constantTimeEqual(candidate, secret),
            let identity
        else { return nil }
        self.secret = nil
        expiryTask?.cancel()
        expiryTask = nil
        return ClaimedCompanionPairing(
            id: pairingSession.id,
            words: CompanionPairingWords.words(macSPKI: identity.subjectPublicKeyInfo, phoneSPKI: phoneSPKI)
        )
    }

    private func finishPairing(id: UUID) {
        guard pairingSession?.id == id else { return }
        pairingResult = .paired
        clearPairingState()
    }

    private func endPairing(result: CompanionPairingResult) {
        pairingResult = result
        clearPairingState()
        resolveApproval(allowed: false)
    }

    private func abortSpentPairing(id: UUID) {
        guard pairingSession?.id == id, secret == nil else { return }
        endPairing(result: .denied)
    }

    private func clearPairingState() {
        expiryTask?.cancel()
        expiryTask = nil
        secret = nil
        pairingSession = nil
        pairingGeneration = nil
        servers.forEach { $0.pairingIsOpen = false }
    }

    private func requestApproval(id: UUID, phoneName: String, words: [String]) async -> Bool {
        guard pairingSession?.id == id else { return false }
        #if DEBUG
            if case .development = profile,
                ProcessInfo.processInfo.environment["AWESOMUX_COMPANION_AUTO_ALLOW"] == "1"
            {
                return true
            }
        #endif
        resolveApproval(allowed: false)
        guard pairingSession?.id == id else { return false }
        return await withCheckedContinuation { continuation in
            pendingApproval = PendingApproval(id: id, continuation: continuation)
            approvalPrompt = CompanionApprovalPrompt(id: id, phoneName: phoneName, words: words)
            Task { [weak self] in
                try? await self?.delay(.seconds(2 * 60))
                guard !Task.isCancelled else { return }
                self?.expireApproval(id: id)
            }
        }
    }

    private func expireApproval(id: UUID) {
        guard pendingApproval?.id == id else { return }
        denyPendingPhone(id: id)
    }

    private func denyPendingPhone(id: UUID) {
        guard pendingApproval?.id == id else { return }
        resolveApproval(allowed: false)
        endPairing(result: .denied)
    }

    private func resolveApproval(allowed: Bool) {
        guard let pendingApproval else {
            approvalPrompt = nil
            return
        }
        self.pendingApproval = nil
        approvalPrompt = nil
        pendingApproval.continuation.resume(returning: allowed)
    }

    private func invalidateConnections(connectionID: UUID?) {
        servers.forEach { $0.invalidate(connectionID: connectionID) }
        if connectionID == nil { stop() }
    }

    private func stopListenerIfIdle() {
        guard pairedPhones.isEmpty, pairingSession == nil, pairingGeneration == nil,
            !servers.contains(where: { $0.hasPendingRevocationReplies })
        else { return }
        stopWatchingNetwork()
        listenerLifecycle = UUID()
        listenerGeneration = UUID()
        servers.forEach { $0.stop() }
        servers = []
        boundAddresses = []
        stablePort = nil
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

private struct PendingApproval {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
}

@MainActor
private final class CompanionNetworkServer {
    let address: CompanionNetworkAddress
    private(set) var port: UInt16?
    var pairingIsOpen: Bool {
        get { verifier.pairingIsOpen }
        set { verifier.pairingIsOpen = newValue }
    }

    private let identity: CompanionIdentity
    private let preferredPort: UInt16?
    private let profile: String
    private let instanceID: UUID
    private let authority: LocalAPIRuntimeAuthority
    private let delay: CompanionDelay
    private let pairedConnections: @MainActor () -> [LocalAPIConnectionGrant]
    private let claimSecret: @MainActor (Data, Data) -> ClaimedCompanionPairing?
    private let requestApproval: @MainActor (UUID, String, [String]) async -> Bool
    private let cancelApproval: @MainActor (UUID) -> Void
    private let abortPairing: @MainActor (UUID) -> Void
    private let register: @MainActor (UUID, String, Data, LocalAPICompanionTransport, UInt16) throws -> LocalAPIConnectionGrant
    private let setAlertPreferences: @MainActor (UUID, CompanionAlertPreferences) throws -> Void
    private let revoke: @MainActor (UUID) throws -> Void
    private let renamePane:
        @MainActor (CompanionPaneRenameRequest, LocalAPIAuthorizationLease, Data, ContinuousClock.Instant) throws -> Void
    private let setTerminalPreview: @MainActor (UUID, Data, LocalAPIAuthorizationLease, Bool) throws -> LocalAPIAuthorizationLease
    private let decisions: @MainActor (CompanionDecisionAnswer?, LocalAPIAuthorizationLease, Data, UUID) throws -> CompanionDecisionResponse
    private let capture: @MainActor (LocalAPIRequest, LocalAPIAuthorizationLease, CompanionRoutes?) async -> CompanionAPIResponse
    private let routes: @MainActor () -> CompanionRoutes?
    private let markActivity: @MainActor () -> Void
    private let markSeen: @MainActor (UUID) -> Void
    private let connectionFinished: @MainActor () -> Void
    private let listenerFailed: @MainActor () -> Void
    private let verifier = CompanionPeerVerifier()
    private let limiter = CompanionAttemptLimiter()
    private let queue = DispatchQueue(label: "awesomux.companion.listener", qos: .utility)
    private var listener: NWListener?
    private var connections: [UUID: ActiveCompanionConnection] = [:]
    private var pendingRevocationReplies: Set<UUID> = []
    private var pendingPermissionReplies: Set<UUID> = []
    private var pendingPreferenceReplies: Set<UUID> = []

    var hasPendingRevocationReplies: Bool { !pendingRevocationReplies.isEmpty }

    init(
        identity: CompanionIdentity,
        address: CompanionNetworkAddress,
        preferredPort: UInt16?,
        profile: String,
        instanceID: UUID,
        authority: LocalAPIRuntimeAuthority,
        delay: @escaping CompanionDelay,
        pairedConnections: @escaping @MainActor () -> [LocalAPIConnectionGrant],
        claimSecret: @escaping @MainActor (Data, Data) -> ClaimedCompanionPairing?,
        requestApproval: @escaping @MainActor (UUID, String, [String]) async -> Bool,
        cancelApproval: @escaping @MainActor (UUID) -> Void,
        abortPairing: @escaping @MainActor (UUID) -> Void,
        register: @escaping @MainActor (UUID, String, Data, LocalAPICompanionTransport, UInt16) throws -> LocalAPIConnectionGrant,
        revoke: @escaping @MainActor (UUID) throws -> Void,
        setAlertPreferences: @escaping @MainActor (UUID, CompanionAlertPreferences) throws -> Void,
        renamePane:
            @escaping @MainActor (CompanionPaneRenameRequest, LocalAPIAuthorizationLease, Data, ContinuousClock.Instant) throws -> Void,
        setTerminalPreview: @escaping @MainActor (UUID, Data, LocalAPIAuthorizationLease, Bool) throws -> LocalAPIAuthorizationLease,
        capture: @escaping @MainActor (LocalAPIRequest, LocalAPIAuthorizationLease, CompanionRoutes?) async -> CompanionAPIResponse,
        routes: @escaping @MainActor () -> CompanionRoutes?,
        markActivity: @escaping @MainActor () -> Void,
        markSeen: @escaping @MainActor (UUID) -> Void,
        connectionFinished: @escaping @MainActor () -> Void,
        decisions:
            @escaping @MainActor (CompanionDecisionAnswer?, LocalAPIAuthorizationLease, Data, UUID) throws -> CompanionDecisionResponse,
        listenerFailed: @escaping @MainActor () -> Void
    ) {
        self.identity = identity
        self.address = address
        self.preferredPort = preferredPort
        self.profile = profile
        self.instanceID = instanceID
        self.authority = authority
        self.delay = delay
        self.pairedConnections = pairedConnections
        self.claimSecret = claimSecret
        self.requestApproval = requestApproval
        self.cancelApproval = cancelApproval
        self.abortPairing = abortPairing
        self.register = register
        self.revoke = revoke
        self.setTerminalPreview = setTerminalPreview
        self.setAlertPreferences = setAlertPreferences
        self.decisions = decisions
        self.capture = capture
        self.renamePane = renamePane
        self.routes = routes
        self.markActivity = markActivity
        self.markSeen = markSeen
        self.connectionFinished = connectionFinished
        self.listenerFailed = listenerFailed
    }

    func start() async throws {
        verifier.replaceFingerprints(activeFingerprints())
        let tls = NWProtocolTLS.Options()
        guard let protocolIdentity = sec_identity_create(identity.identity) else {
            throw CompanionPairingError.identityUnavailable
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, protocolIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
        let verifier = self.verifier
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            Self.makeVerifyBlock(verifier: verifier),
            queue
        )
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(address.host),
            port: preferredPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
        )
        let listener = try NWListener(using: parameters)
        self.listener = listener
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        guard resumed.claim() else { return }
                        self?.port = listener.port?.rawValue
                        continuation.resume()
                    case .failed, .cancelled:
                        if resumed.claim() {
                            continuation.resume(throwing: CompanionPairingError.listenerUnavailable)
                        } else if self?.listener === listener {
                            self?.listenerFailed()
                        }
                    // Starts are serialized, so a start parked in .waiting would block every later recovery.
                    case .waiting:
                        guard resumed.claim() else { return }
                        listener.cancel()
                        continuation.resume(throwing: CompanionPairingError.listenerUnavailable)
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for active in connections.values {
            active.worker?.cancel()
            active.connection.cancel()
        }
        connections.removeAll()
    }

    func refreshAuthorization() {
        verifier.replaceFingerprints(activeFingerprints())
    }

    func invalidate(connectionID: UUID?) {
        for (id, active) in connections where connectionID == nil || active.connectionID == connectionID {
            if connectionID != nil,
                pendingRevocationReplies.contains(id) || pendingPermissionReplies.contains(id) || pendingPreferenceReplies.contains(id)
            {
                continue
            }
            active.worker?.cancel()
            active.connection.cancel()
            connections.removeValue(forKey: id)
        }
        verifier.replaceFingerprints(activeFingerprints())
    }

    private func accept(_ connection: NWConnection) {
        let remote = Self.remoteAddress(connection.endpoint)
        guard connections.count < LocalAPIContract.maximumClients, limiter.allows(remote, kind: .handshake) else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = ActiveCompanionConnection(connection: connection, connectionID: nil, isReady: false, worker: nil)
        let handshakeDeadline = Task { [weak self] in
            try? await self?.delay(.seconds(LocalAPIContract.timeout))
            guard !Task.isCancelled, let self, self.connections[id]?.isReady == false else { return }
            self.connections[id]?.connection.cancel()
            self.connections.removeValue(forKey: id)
            self.limiter.recordFailure(remote, kind: .handshake)
        }
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    handshakeDeadline.cancel()
                    self.connections[id]?.isReady = true
                    let worker = Task { await self.serve(id: id, connection: connection, remote: remote) }
                    self.connections[id]?.worker = worker
                case .failed:
                    handshakeDeadline.cancel()
                    guard let active = self.connections[id] else { return }
                    if active.isReady {
                        active.worker?.cancel()
                    } else {
                        self.limiter.recordFailure(remote, kind: .handshake)
                        self.connections.removeValue(forKey: id)
                    }
                case .cancelled:
                    handshakeDeadline.cancel()
                    guard let active = self.connections[id] else { return }
                    if active.isReady {
                        active.worker?.cancel()
                    } else {
                        self.connections.removeValue(forKey: id)
                    }
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    private func serve(id: UUID, connection: NWConnection, remote: String) async {
        defer {
            connection.cancel()
            connections.removeValue(forKey: id)
            connectionFinished()
        }
        do {
            let phoneSPKI = try Self.peerSPKI(connection)
            let fingerprint = Data(SHA256.hash(data: phoneSPKI))
            let pairedAtHandshake = pairedConnections().first {
                $0.companion?.certificateFingerprint == fingerprint && $0.companion?.allows(address.transport) == true
            }
            connections[id]?.connectionID = pairedAtHandshake?.id
            let isPaired = pairedAtHandshake != nil
            guard isPaired || (pairingIsOpen && limiter.allows(remote, kind: .pairing)) else { return }
            let firstFrameDeadline = Task { [delay] in
                try? await delay(.seconds(LocalAPIContract.timeout))
                guard !Task.isCancelled else { return }
                connection.cancel()
            }
            defer { firstFrameDeadline.cancel() }
            let data: Data
            do {
                data = try await Self.readFrame(connection, maximum: LocalAPIContract.maximumRequestBytes)
            } catch let error as LocalAPIError {
                if isPaired {
                    try? await Self.sendFrame(
                        try LocalAPIContract.encoder().encode(LocalAPIResponse(error: error)), connection: connection
                    )
                }
                return
            }
            firstFrameDeadline.cancel()
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if pairingIsOpen, object?["op"] as? String == "pair" {
                try await servePairing(connection, data: data, remote: remote, phoneSPKI: phoneSPKI, fingerprint: fingerprint)
            } else if let paired = pairedConnections().first(where: {
                $0.companion?.certificateFingerprint == fingerprint && $0.companion?.allows(address.transport) == true
            }) {
                connections[id]?.connectionID = paired.id
                try await serveAuthorized(connection, id: id, data: data, connectionID: paired.id, fingerprint: fingerprint)
            } else {
                try await servePairing(
                    connection,
                    data: data,
                    remote: remote,
                    phoneSPKI: phoneSPKI,
                    fingerprint: fingerprint
                )
            }
        } catch {
            return
        }
    }

    private func serveAuthorized(_ connection: NWConnection, id: UUID, data: Data, connectionID: UUID, fingerprint: Data) async throws {
        let mutationDeadline = ContinuousClock.now.advanced(by: .seconds(LocalAPIContract.timeout))
        let deadline = Task { [delay] in
            try? await delay(.seconds(LocalAPIContract.timeout))
            guard !Task.isCancelled else { return }
            connection.cancel()
        }
        defer { deadline.cancel() }
        var requestID: UUID?
        let responseProgress = ResponseProgress()
        do {
            guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                Set(object.keys).isSubset(of: [
                    "schemaVersion", "requestID", "profile", "operation", "connectionID", "paneID", "targetVersion", "limit", "source",
                    "cursor", "includeCommandEvents", "workspaceID", "title", "terminalPreviewAllowed", "alertPreferences",
                    "decisionAnswer",
                ])
            else { throw LocalAPIError.invalidRequest }
            requestID = (object["requestID"] as? String).flatMap(UUID.init(uuidString:))
            if object["profile"] == nil { object["profile"] = profile }
            let normalized = try JSONSerialization.data(withJSONObject: object)
            guard let request = try? LocalAPIContract.decoder().decode(LocalAPIRequest.self, from: normalized) else {
                throw LocalAPIError.invalidRequest
            }
            requestID = request.requestID
            guard request.schemaVersion == LocalAPIContract.version else { throw LocalAPIError.unsupportedVersion }
            guard request.profile == profile else { throw LocalAPIError.profileMismatch }
            guard request.connectionID == connectionID else { throw LocalAPIError.permissionDenied }
            if request.operation == CompanionOperation.getAlertPreferences.rawValue
                || request.operation == CompanionOperation.setAlertPreferences.rawValue
            {
                let isSet = request.operation == CompanionOperation.setAlertPreferences.rawValue
                let required: Set<String> = ["schemaVersion", "requestID", "operation", "connectionID", "profile"]
                guard Set(object.keys) == (isSet ? required.union(["alertPreferences"]) : required) else {
                    throw LocalAPIError.invalidRequest
                }
                var lease = try authority.authorizeCompanion(
                    connectionID: connectionID, certificateFingerprint: fingerprint, operation: .connectionStatus
                ).get()
                markActivity()
                defer { pendingPreferenceReplies.remove(id) }
                if isSet {
                    guard let payload = object["alertPreferences"] as? [String: Any], Set(payload.keys) == ["categories"],
                        let data = try? JSONSerialization.data(withJSONObject: payload),
                        let preferences = try? CompanionProtocol.decoder().decode(CompanionAlertPreferences.self, from: data)
                    else { throw LocalAPIError.invalidRequest }
                    guard !Task.isCancelled else { throw LocalAPIError.cancelled }
                    guard ContinuousClock.now < mutationDeadline else { throw LocalAPIError.timeout }
                    if case .cancelled = connection.state { throw LocalAPIError.cancelled }
                    // The setter invalidates old requests. This receipt uses the
                    // replacement lease and still rechecks authority before every chunk.
                    pendingPreferenceReplies.insert(id)
                    do {
                        try setAlertPreferences(connectionID, preferences)
                    } catch {
                        pendingPreferenceReplies.remove(id)
                        throw LocalAPIError.transportFailure
                    }
                    lease = try authority.authorizeCompanion(
                        connectionID: connectionID, certificateFingerprint: fingerprint, operation: .connectionStatus
                    ).get()
                }
                let response = CompanionAPIResponse(
                    requestID: request.requestID, profile: profile, appInstanceID: instanceID, capturedAt: Date(),
                    alertPreferences: lease.companionAlertPreferences)
                try await sendAuthorizedFrame(
                    try CompanionProtocol.encoder().encode(response), connection: connection,
                    connectionID: connectionID, fingerprint: fingerprint, lease: lease, responseProgress: responseProgress)
                markSeen(connectionID)
                return
            }
            guard object["alertPreferences"] == nil else { throw LocalAPIError.invalidRequest }
            if request.operation == CompanionOperation.pendingDecisions.rawValue
                || request.operation == CompanionOperation.answerDecision.rawValue
            {
                let base: Set<String> = ["schemaVersion", "requestID", "profile", "operation", "connectionID"]
                let isAnswer = request.operation == CompanionOperation.answerDecision.rawValue
                guard Set(object.keys) == (isAnswer ? base.union(["decisionAnswer"]) : base) else { throw LocalAPIError.invalidRequest }
                let answer: CompanionDecisionAnswer?
                if isAnswer {
                    guard let payload = object["decisionAnswer"] as? [String: Any],
                        Set(payload.keys) == ["identity", "choice", "retryID"],
                        let identity = payload["identity"] as? [String: Any],
                        Set(identity.keys) == [
                            "runtimeID", "workspaceID", "paneID", "targetVersion", "providerSessionID", "invocationID", "revision",
                        ]
                    else { throw LocalAPIError.invalidRequest }
                    guard
                        let decoded = try? CompanionProtocol.decoder().decode(
                            CompanionDecisionAnswer.self,
                            from: JSONSerialization.data(withJSONObject: payload))
                    else { throw LocalAPIError.invalidRequest }
                    answer = decoded
                    guard let answer, answer.identity.revision > 0,
                        !answer.identity.providerSessionID.isEmpty, answer.identity.providerSessionID.utf8.count <= 256
                    else { throw LocalAPIError.invalidRequest }
                } else {
                    answer = nil
                }
                let lease = try authority.authorizeCompanion(
                    connectionID: connectionID,
                    certificateFingerprint: fingerprint, operation: .connectionStatus
                ).get()
                if case .cancelled = connection.state { throw LocalAPIError.cancelled }
                let projection = try decisions(answer, lease, fingerprint, request.requestID)
                let encoded = try CompanionProtocol.encoder().encode(projection.response)
                guard encoded.count <= LocalAPIContract.maximumResponseBytes else { throw LocalAPIError.responseTooLarge }
                try await sendAuthorizedFrame(
                    encoded, connection: connection, connectionID: connectionID,
                    fingerprint: fingerprint, lease: lease, responseProgress: responseProgress, validate: projection.validate)
                markSeen(connectionID)
                return
            }
            guard object["decisionAnswer"] == nil else { throw LocalAPIError.invalidRequest }
            if request.operation == CompanionPaneRename.operation {
                let mutation = try CompanionPaneRenameRequest.decode(object)
                let lease = try authority.authorizeCompanion(
                    connectionID: connectionID, certificateFingerprint: fingerprint, operation: .connectionStatus
                ).get()
                markActivity()
                if case .cancelled = connection.state { throw LocalAPIError.cancelled }
                try renamePane(mutation, lease, fingerprint, mutationDeadline)
                let response = LocalAPIResponse(
                    requestID: request.requestID, profile: profile, appInstanceID: instanceID, capturedAt: Date())
                try await sendAuthorizedFrame(
                    try CompanionProtocol.encoder().encode(response.companionResponse), connection: connection,
                    connectionID: connectionID, fingerprint: fingerprint, lease: lease, responseProgress: responseProgress)
                markSeen(connectionID)
                return
            }
            guard object["workspaceID"] == nil, object["title"] == nil else { throw LocalAPIError.invalidRequest }
            if object.keys.contains("terminalPreviewAllowed"),
                request.operation != CompanionOperation.setTerminalPreview.rawValue
            {
                throw LocalAPIError.invalidRequest
            }
            let isUnpair = request.operation == CompanionOperation.unpair.rawValue
            let operation = try CompanionRequestPolicy.authorizationOperation(for: request)
            guard operation == .attentionEvents || object["includeCommandEvents"] == nil else {
                throw LocalAPIError.invalidRequest
            }
            let lease = try authority.authorizeCompanion(
                connectionID: connectionID,
                certificateFingerprint: fingerprint,
                operation: operation
            ).get()
            markActivity()
            if request.operation == CompanionOperation.setTerminalPreview.rawValue {
                guard let allowed = request.terminalPreviewAllowed else { throw LocalAPIError.invalidRequest }
                // Keep this socket alive through its own invalidation; unlike
                // self-unpair, the acknowledgement still requires a current lease.
                pendingPermissionReplies.insert(id)
                defer { pendingPermissionReplies.remove(id) }
                let updatedLease: LocalAPIAuthorizationLease
                do {
                    updatedLease = try setTerminalPreview(connectionID, fingerprint, lease, allowed)
                } catch let error as LocalAPIError {
                    throw error
                } catch {
                    throw LocalAPIError.transportFailure
                }
                let receipt = CompanionAPIResponse(
                    requestID: request.requestID, profile: profile, appInstanceID: instanceID,
                    capturedAt: Date(), terminalPreviewAllowed: updatedLease.terminalPreviewAllowed
                )
                try await sendAuthorizedFrame(
                    try CompanionProtocol.encoder().encode(receipt), connection: connection,
                    connectionID: connectionID, fingerprint: fingerprint, lease: updatedLease,
                    responseProgress: responseProgress
                )
                markSeen(connectionID)
                return
            }
            if isUnpair {
                pendingRevocationReplies.insert(id)
                defer { pendingRevocationReplies.remove(id) }
                var revocationError: LocalAPIError?
                do {
                    try revoke(lease.connectionID)
                } catch {
                    revocationError = .transportFailure
                }
                invalidate(connectionID: lease.connectionID)
                // Revocation invalidates the lease. Only this payload-free receipt
                // may finish; other connections and future requests stay revoked.
                let response =
                    if let revocationError {
                        LocalAPIResponse(requestID: request.requestID, error: revocationError)
                    } else {
                        LocalAPIResponse(requestID: request.requestID, profile: profile, appInstanceID: instanceID, capturedAt: Date())
                    }
                responseProgress.markStarted()
                try await Self.sendFrame(try CompanionProtocol.encoder().encode(response.companionResponse), connection: connection)
                return
            }
            let metadata = pairedConnections().first { $0.id == connectionID }?.companion
            let response = await capture(
                request, lease, operation == .connectionStatus && metadata?.pairingVersion == 2 ? routes() : nil)
            let encoded = try CompanionProtocol.encoder().encode(response)
            guard encoded.count <= LocalAPIContract.maximumResponseBytes else { throw LocalAPIError.responseTooLarge }
            try await sendAuthorizedFrame(
                encoded,
                connection: connection,
                connectionID: connectionID,
                fingerprint: fingerprint,
                lease: lease,
                responseProgress: responseProgress
            )
            markSeen(connectionID)
        } catch let error as LocalAPIError {
            guard !responseProgress.started else { return }
            try? await Self.sendFrame(
                try CompanionProtocol.encoder().encode(LocalAPIResponse(requestID: requestID, error: error).companionResponse),
                connection: connection
            )
        }
    }

    private func servePairing(
        _ connection: NWConnection,
        data: Data,
        remote: String,
        phoneSPKI: Data,
        fingerprint: Data
    ) async throws {
        guard pairingIsOpen, limiter.allows(remote, kind: .pairing) else { throw CompanionPairingError.invalidRequest }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            Set(object.keys) == ["v", "op", "secret", "phoneName"],
            object["v"] as? Int == 1,
            object["op"] as? String == "pair",
            let encodedSecret = object["secret"] as? String,
            let candidate = LocalAPICredential.decode(encodedSecret),
            let rawPhoneName = object["phoneName"] as? String
        else {
            limiter.recordFailure(remote, kind: .pairing)
            try? await Self.sendFrame(Self.pairingReply(status: "denied"), connection: connection)
            return
        }
        let trimmedPhoneName = rawPhoneName.trimmingCharacters(in: .whitespacesAndNewlines)
        let phoneName = UnicodeHygiene.sanitize(trimmedPhoneName, maxLength: 80, stripInvisibleRoutingScalars: true)
        guard !phoneName.isEmpty, trimmedPhoneName.count <= 80 else {
            limiter.recordFailure(remote, kind: .pairing)
            try await Self.sendFrame(Self.pairingReply(status: "denied"), connection: connection)
            return
        }
        guard let claimedPairing = claimSecret(candidate, phoneSPKI) else {
            limiter.recordFailure(remote, kind: .pairing)
            try await Self.sendFrame(Self.pairingReply(status: "denied"), connection: connection)
            return
        }
        let approvalID = claimedPairing.id
        let peerState = PairingPeerState()
        let cancelApproval = self.cancelApproval
        let abortPairing = self.abortPairing
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, complete, error in
            guard data != nil || complete || error != nil else { return }
            guard peerState.invalidate() else { return }
            Task { @MainActor in
                cancelApproval(approvalID)
                abortPairing(claimedPairing.id)
            }
        }
        do {
            try await Self.sendFrame(Self.pairingReply(status: "confirm"), connection: connection)
        } catch {
            abortPairing(claimedPairing.id)
            throw error
        }
        guard await requestApproval(approvalID, phoneName, claimedPairing.words), peerState.isValid, pairingIsOpen,
            let port
        else {
            try? await Self.sendFrame(Self.pairingReply(status: "denied"), connection: connection)
            peerState.disarm()
            return
        }
        peerState.disarm()
        let grant: LocalAPIConnectionGrant
        do {
            grant = try register(claimedPairing.id, phoneName, fingerprint, address.transport, port)
        } catch {
            abortPairing(claimedPairing.id)
            try? await Self.sendFrame(Self.pairingReply(status: "denied"), connection: connection)
            return
        }
        verifier.replaceFingerprints(activeFingerprints())
        let macName = Host.current().localizedName ?? String(localized: "This Mac")
        try await Self.sendFrame(
            Self.pairingReply(
                status: "paired",
                connectionID: grant.id,
                macName: macName
            ),
            connection: connection
        )
    }

    private func sendAuthorizedFrame(
        _ payload: Data,
        connection: NWConnection,
        connectionID: UUID,
        fingerprint: Data,
        lease: LocalAPIAuthorizationLease,
        responseProgress: ResponseProgress,
        validate: @MainActor () throws -> Void = {}
    ) async throws {
        let frame = try CompanionFrame.encode(payload, maximum: CompanionProtocol.maximumResponseBytes)
        var offset = 0
        while offset < frame.count {
            let end = min(offset + 16 * 1024, frame.count)
            let chunk = frame[offset..<end]
            try validate()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                do {
                    _ = try authority.commitCompanion(
                        connectionID: connectionID,
                        certificateFingerprint: fingerprint,
                        lease: lease
                    ) {
                        responseProgress.markStarted()
                        connection.send(
                            content: Data(chunk),
                            completion: .contentProcessed { error in
                                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                            })
                        return chunk.count
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            offset = end
        }
    }

    private static func readFrame(_ connection: NWConnection, maximum: Int) async throws -> Data {
        let header = try await receive(connection, minimum: 4, maximum: 4)
        guard header.count == 4 else { throw CompanionPairingError.connectionClosed }
        let length: Int
        do {
            length = try CompanionFrame.payloadLength(header, maximum: maximum)
        } catch {
            throw LocalAPIError.requestTooLarge
        }
        let body = try await receive(connection, minimum: Int(length), maximum: Int(length))
        guard body.count == Int(length) else { throw CompanionPairingError.connectionClosed }
        return body
    }

    private static func receive(_ connection: NWConnection, minimum: Int, maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: minimum, maximumLength: maximum) { data, _, complete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if complete, data == nil {
                    continuation.resume(throwing: CompanionPairingError.connectionClosed)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: CompanionPairingError.connectionClosed)
                }
            }
        }
    }

    private static func sendFrame(_ payload: Data, connection: NWConnection) async throws {
        let frame = try CompanionFrame.encode(payload, maximum: CompanionProtocol.maximumResponseBytes)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: frame,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
    }

    private static func pairingReply(status: String, connectionID: UUID? = nil, macName: String? = nil) -> Data {
        (try? CompanionProtocol.encoder().encode(
            CompanionPairingReply(status: status, connectionID: connectionID, macName: macName)
        )) ?? Data()
    }

    private static func peerSPKI(_ connection: NWConnection) throws -> Data {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            throw CompanionPairingError.invalidRequest
        }
        let box = PeerCertificateBox()
        guard
            sec_protocol_metadata_access_peer_certificate_chain(
                metadata.securityProtocolMetadata,
                { certificate in
                    box.storeIfEmpty(sec_certificate_copy_ref(certificate).takeRetainedValue())
                }), let certificate = box.certificate
        else { throw CompanionPairingError.invalidRequest }
        return try CompanionCertificate.subjectPublicKeyInfo(for: certificate)
    }

    private static func remoteAddress(_ endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return String(describing: endpoint) }
        return String(describing: host)
    }

    nonisolated private static func makeVerifyBlock(verifier: CompanionPeerVerifier) -> sec_protocol_verify_t {
        { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                let leaf = chain.first
            else {
                complete(false)
                return
            }
            complete(verifier.accepts(leaf))
        }
    }

    private func activeFingerprints() -> [Data] {
        pairedConnections().compactMap { connection in
            guard connection.companion?.allows(address.transport) == true else { return nil }
            return connection.companion?.certificateFingerprint
        }
    }
}

private final class PairingPeerState: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    private var armed = true

    var isValid: Bool { lock.withLock { valid } }

    func invalidate() -> Bool {
        lock.withLock {
            guard armed else { return false }
            valid = false
            return true
        }
    }

    func disarm() { lock.withLock { armed = false } }
}

private final class ResponseProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false

    var started: Bool { lock.withLock { didStart } }

    func markStarted() { lock.withLock { didStart = true } }
}

private struct ActiveCompanionConnection {
    let connection: NWConnection
    var connectionID: UUID?
    var isReady: Bool
    var worker: Task<Void, Never>?
}

private final class CompanionPeerVerifier: @unchecked Sendable {
    private let lock = NSLock()
    private var fingerprints = Set<Data>()
    private var isPairingOpen = false

    var pairingIsOpen: Bool {
        get { lock.withLock { isPairingOpen } }
        set { lock.withLock { isPairingOpen = newValue } }
    }

    func replaceFingerprints(_ values: [Data]) {
        lock.withLock { fingerprints = Set(values) }
    }

    func accepts(_ certificate: SecCertificate) -> Bool {
        guard let spki = try? CompanionCertificate.subjectPublicKeyInfo(for: certificate) else { return false }
        let fingerprint = Data(SHA256.hash(data: spki))
        return lock.withLock {
            fingerprints.contains(fingerprint) || (isPairingOpen && CompanionCertificate.isSelfSigned(certificate))
        }
    }
}

private final class PeerCertificateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SecCertificate?

    var certificate: SecCertificate? { lock.withLock { stored } }

    func storeIfEmpty(_ certificate: SecCertificate) {
        lock.withLock {
            if stored == nil { stored = certificate }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

private final class CompanionAttemptLimiter: @unchecked Sendable {
    enum Kind: Hashable { case handshake, pairing }

    private struct Key: Hashable { let remote: String; let kind: Kind }
    private let lock = NSLock()
    private var failures: [Key: [ContinuousClock.Instant]] = [:]

    func allows(_ remote: String, kind: Kind) -> Bool {
        lock.withLock {
            prune()
            let limit = kind == .handshake ? 8 : 5
            return failures[Key(remote: remote, kind: kind), default: []].count < limit
        }
    }

    func recordFailure(_ remote: String, kind: Kind) {
        lock.withLock {
            prune()
            failures[Key(remote: remote, kind: kind), default: []].append(.now)
        }
    }

    private func prune() {
        let cutoff = ContinuousClock.now.advanced(by: .seconds(-60))
        failures = failures.compactMapValues { timestamps in
            let recent = timestamps.filter { $0 >= cutoff }
            return recent.isEmpty ? nil : recent
        }
    }
}
