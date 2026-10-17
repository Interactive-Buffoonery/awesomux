import AppKit
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

struct CompanionNetworkAddress: Equatable, Sendable {
    let interfaceName: String
    let host: String
    let transport: LocalAPICompanionTransport
}

struct CompanionPairingSession: Identifiable, Equatable, Sendable {
    let id: UUID
    let transport: LocalAPICompanionTransport
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
    case noTailscaleAddress
    case transportInUse
    case identityUnavailable
    case listenerUnavailable
    case invalidWords
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
    private(set) var activeTransport: LocalAPICompanionTransport?
    private(set) var listenerErrorMessage: String?
    private(set) var lastSeen: [UUID: Date] = [:]

    @ObservationIgnored private let profile: AppRuntimeProfile
    @ObservationIgnored private let accessStore: LocalAPIAccessStore
    @ObservationIgnored private let delay: CompanionDelay
    @ObservationIgnored private var identity: CompanionIdentity?
    @ObservationIgnored private var service: LocalAPIService?
    @ObservationIgnored private var server: CompanionNetworkServer?
    @ObservationIgnored private var secret: Data?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var pendingApproval: PendingApproval?
    @ObservationIgnored private var pairingGeneration: UUID?
    @ObservationIgnored private var listenerGeneration = UUID()

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

    var availableTransports: [LocalAPICompanionTransport] {
        let addresses = Self.interfaceAddresses()
        var transports: [LocalAPICompanionTransport] = [.lan]
        if addresses.contains(where: { $0.transport == .tailscale }) { transports.append(.tailscale) }
        return transports
    }

    var persistenceFailureMessage: String? { accessStore.persistenceFailureMessage }

    func configure(service: LocalAPIService) {
        guard self.service == nil else { return }
        self.service = service
        accessStore.setCompanionInvalidationHandler { [weak self] connectionID in
            Task { @MainActor in self?.invalidateConnections(connectionID: connectionID) }
        }
        if let mostRecent = pairedPhones.last, let metadata = mostRecent.companion {
            Task { await startListener(transport: metadata.transport, preferredPort: metadata.port) }
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
                        let session = try await beginPairing(transport: .lan)
                        try Data((session.link + "\n").utf8).write(to: URL(fileURLWithPath: linkPath), options: .atomic)
                    } catch {
                        listenerErrorMessage = String(localized: "Companion pairing could not start.")
                    }
                }
            }
        #endif
    }

    func beginPairing(transport: LocalAPICompanionTransport) async throws -> CompanionPairingSession {
        guard pairedPhones.allSatisfy({ $0.companion?.transport == transport }) else {
            throw CompanionPairingError.transportInUse
        }
        cancelPairing()
        pairingResult = nil
        let generation = UUID()
        pairingGeneration = generation
        let address = try Self.address(for: transport)
        let loadedIdentity: CompanionIdentity
        do {
            loadedIdentity = try identity ?? CompanionIdentityStore.loadOrCreate(profile: profile.environmentValue)
        } catch {
            throw CompanionPairingError.identityUnavailable
        }
        identity = loadedIdentity
        let preferredPort = pairedPhones.last?.companion?.port
        try await replaceListener(identity: loadedIdentity, address: address, preferredPort: preferredPort)
        guard pairingGeneration == generation, !Task.isCancelled else {
            throw CompanionPairingError.connectionClosed
        }
        guard let port = server?.port else { throw CompanionPairingError.listenerUnavailable }
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
        var components = URLComponents()
        components.scheme = "awesomuxcompanion"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "h", value: address.host),
            URLQueryItem(name: "p", value: String(port)),
            URLQueryItem(name: "fp", value: loadedIdentity.fingerprint.companionBase64URL),
            URLQueryItem(name: "s", value: generatedSecret.companionBase64URL),
            URLQueryItem(name: "n", value: macName),
            URLQueryItem(name: "t", value: transport.rawValue),
        ]
        guard let link = components.string else { throw CompanionPairingError.invalidRequest }
        let session = CompanionPairingSession(id: id, transport: transport, link: link, expiresAt: expiresAt)
        pairingSession = session
        server?.pairingIsOpen = true
        expiryTask = Task { [weak self] in
            try? await self?.delay(.seconds(5 * 60))
            guard !Task.isCancelled else { return }
            self?.expirePairing(id: id)
        }
        return session
    }

    func cancelPairing() {
        let wasStarting = pairingGeneration != nil && pairingSession == nil
        let hadPendingApproval = pendingApproval != nil
        expiryTask?.cancel()
        expiryTask = nil
        secret = nil
        pairingSession = nil
        server?.pairingIsOpen = false
        pairingGeneration = nil
        if wasStarting { listenerGeneration = UUID() }
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

    func unpair(_ connection: LocalAPIConnectionGrant) throws {
        try accessStore.revoke(connectionID: connection.id)
        lastSeen.removeValue(forKey: connection.id)
        stopListenerIfIdle()
    }

    func stop() {
        cancelPairing()
        server?.stop()
        server = nil
        activeTransport = nil
    }

    private func expirePairing(id: UUID) {
        guard pairingSession?.id == id else { return }
        endPairing(result: .expired)
        stopListenerIfIdle()
    }

    private func startListener(transport: LocalAPICompanionTransport, preferredPort: UInt16) async {
        do {
            let loadedIdentity = try identity ?? CompanionIdentityStore.loadOrCreate(profile: profile.environmentValue)
            identity = loadedIdentity
            try await replaceListener(
                identity: loadedIdentity,
                address: try Self.address(for: transport),
                preferredPort: preferredPort
            )
        } catch {
            listenerErrorMessage = String(localized: "Companion is not listening. Open Settings and try pairing again.")
        }
    }

    private func replaceListener(
        identity: CompanionIdentity,
        address: CompanionNetworkAddress,
        preferredPort: UInt16?
    ) async throws {
        if let server, server.address == address, preferredPort == nil || server.port == preferredPort {
            activeTransport = address.transport
            listenerErrorMessage = nil
            return
        }
        server?.stop()
        server = nil
        guard let service else { throw CompanionPairingError.listenerUnavailable }
        let generation = UUID()
        listenerGeneration = generation
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
                    port: port
                )
                self.finishPairing(id: pairingID)
                return grant
            },
            capture: { request, lease in
                await service.companionResponse(request: request, lease: lease)
            },
            markSeen: { [weak self] connectionID in self?.lastSeen[connectionID] = Date() },
            connectionFinished: { [weak self] in self?.stopListenerIfIdle() },
            listenerFailed: { [weak self] in
                guard let self, self.listenerGeneration == generation else { return }
                if self.pairingSession != nil {
                    self.endPairing(result: .denied)
                } else {
                    self.resolveApproval(allowed: false)
                }
                self.server = nil
                self.activeTransport = nil
                self.listenerErrorMessage = String(localized: "Companion is not listening. Open Settings and try pairing again.")
            }
        )
        try await newServer.start()
        guard listenerGeneration == generation, !Task.isCancelled else {
            newServer.stop()
            throw CompanionPairingError.connectionClosed
        }
        server = newServer
        activeTransport = address.transport
        listenerErrorMessage = nil
    }

    private func claimSecret(_ candidate: Data, phoneSPKI: Data) -> ClaimedCompanionPairing? {
        guard let pairingSession, pairingSession.expiresAt > Date(),
            let secret, Self.constantTimeEqual(candidate, secret),
            let identity,
            let words = try? Self.confirmationWords(macSPKI: identity.subjectPublicKeyInfo, phoneSPKI: phoneSPKI)
        else { return nil }
        self.secret = nil
        expiryTask?.cancel()
        expiryTask = nil
        return ClaimedCompanionPairing(id: pairingSession.id, words: words)
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
        server?.pairingIsOpen = false
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
        server?.invalidate(connectionID: connectionID)
        if connectionID == nil { server?.stop() }
    }

    private func stopListenerIfIdle() {
        guard pairedPhones.isEmpty, pairingSession == nil else { return }
        server?.stop()
        server = nil
        activeTransport = nil
    }

    private static func confirmationWords(macSPKI: Data, phoneSPKI: Data) throws -> [String] {
        let words = try pairingWords()
        let digest = SHA256.hash(data: macSPKI + phoneSPKI)
        return digest.prefix(3).map { words[Int($0)] }
    }

    private static func pairingWords() throws -> [String] {
        guard let url = Bundle.main.url(forResource: "companion-pairing-words", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { throw CompanionPairingError.invalidWords }
        let words = text.split(whereSeparator: \.isNewline).map(String.init)
        guard words.count == 256, Set(words).count == 256 else { throw CompanionPairingError.invalidWords }
        return words
    }

    private static func address(for transport: LocalAPICompanionTransport) throws -> CompanionNetworkAddress {
        let addresses = interfaceAddresses().filter { $0.transport == transport }
        guard
            let address = addresses.sorted(by: { lhs, rhs in
                if lhs.interfaceName == "en0" { return true }
                if rhs.interfaceName == "en0" { return false }
                return lhs.interfaceName < rhs.interfaceName
            }).first
        else {
            throw transport == .tailscale ? CompanionPairingError.noTailscaleAddress : CompanionPairingError.noLocalAddress
        }
        return address
    }

    private static func interfaceAddresses() -> [CompanionNetworkAddress] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        var result: [CompanionNetworkAddress] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current?.pointee {
            defer { current = entry.ifa_next }
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                entry.ifa_flags & UInt32(IFF_UP) != 0,
                entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            var ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let host = String(
                decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            let bits = UInt32(bigEndian: ipv4.s_addr)
            if bits & 0xFFC0_0000 == 0x6440_0000 {
                result.append(
                    CompanionNetworkAddress(
                        interfaceName: String(cString: entry.ifa_name), host: host, transport: .tailscale
                    ))
            } else if bits & 0xFFFF_0000 != 0xA9FE_0000 {
                result.append(
                    CompanionNetworkAddress(interfaceName: String(cString: entry.ifa_name), host: host, transport: .lan)
                )
            }
        }
        return result
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
    private let capture: @MainActor (LocalAPIRequest, LocalAPIAuthorizationLease) async -> LocalAPIResponse
    private let markSeen: @MainActor (UUID) -> Void
    private let connectionFinished: @MainActor () -> Void
    private let listenerFailed: @MainActor () -> Void
    private let verifier = CompanionPeerVerifier()
    private let limiter = CompanionAttemptLimiter()
    private let queue = DispatchQueue(label: "awesomux.companion.listener", qos: .utility)
    private var listener: NWListener?
    private var connections: [UUID: ActiveCompanionConnection] = [:]

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
        capture: @escaping @MainActor (LocalAPIRequest, LocalAPIAuthorizationLease) async -> LocalAPIResponse,
        markSeen: @escaping @MainActor (UUID) -> Void,
        connectionFinished: @escaping @MainActor () -> Void,
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
        self.capture = capture
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
                    case .failed:
                        if resumed.claim() {
                            continuation.resume(throwing: CompanionPairingError.listenerUnavailable)
                        } else {
                            self?.listenerFailed()
                        }
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
        listener?.cancel()
        listener = nil
        for active in connections.values {
            active.worker?.cancel()
            active.connection.cancel()
        }
        connections.removeAll()
    }

    func invalidate(connectionID: UUID?) {
        for (id, active) in connections where connectionID == nil || active.connectionID == connectionID {
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
            if let paired = pairedConnections().first(where: {
                $0.companion?.certificateFingerprint == fingerprint && $0.companion?.transport == address.transport
            }) {
                connections[id]?.connectionID = paired.id
                try await serveAuthorized(connection, connectionID: paired.id, fingerprint: fingerprint)
            } else {
                try await servePairing(
                    connection,
                    remote: remote,
                    phoneSPKI: phoneSPKI,
                    fingerprint: fingerprint
                )
            }
        } catch {
            return
        }
    }

    private func serveAuthorized(_ connection: NWConnection, connectionID: UUID, fingerprint: Data) async throws {
        let deadline = Task { [delay] in
            try? await delay(.seconds(LocalAPIContract.timeout))
            guard !Task.isCancelled else { return }
            connection.cancel()
        }
        defer { deadline.cancel() }
        var requestID: UUID?
        let responseProgress = ResponseProgress()
        do {
            let data = try await Self.readFrame(connection, maximum: LocalAPIContract.maximumRequestBytes)
            guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                Set(object.keys).isSubset(of: [
                    "schemaVersion", "requestID", "profile", "operation", "connectionID", "paneID", "targetVersion", "limit", "source",
                    "cursor",
                ])
            else { throw LocalAPIError.invalidRequest }
            if object["profile"] == nil { object["profile"] = profile }
            let normalized = try JSONSerialization.data(withJSONObject: object)
            guard let request = try? LocalAPIContract.decoder().decode(LocalAPIRequest.self, from: normalized) else {
                throw LocalAPIError.invalidRequest
            }
            requestID = request.requestID
            guard request.schemaVersion == LocalAPIContract.version else { throw LocalAPIError.unsupportedVersion }
            guard request.profile == profile else { throw LocalAPIError.profileMismatch }
            guard request.connectionID == connectionID else { throw LocalAPIError.permissionDenied }
            guard let operation = LocalAPIOperation(rawValue: request.operation) else {
                throw LocalAPIError.unsupportedOperation
            }
            guard operation == .connectionStatus || operation == .listAgents || operation == .attentionEvents else {
                throw LocalAPIError.permissionDenied
            }
            guard Self.argumentsAreValid(request, operation: operation) else { throw LocalAPIError.invalidRequest }
            let lease = try authority.authorizeCompanion(
                connectionID: connectionID,
                certificateFingerprint: fingerprint,
                operation: operation
            ).get()
            let response = await capture(request, lease)
            let encoded = try LocalAPIContract.encoder().encode(response)
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
                try LocalAPIContract.encoder().encode(LocalAPIResponse(requestID: requestID, error: error)),
                connection: connection
            )
        }
    }

    private func servePairing(
        _ connection: NWConnection,
        remote: String,
        phoneSPKI: Data,
        fingerprint: Data
    ) async throws {
        guard pairingIsOpen, limiter.allows(remote, kind: .pairing) else { throw CompanionPairingError.invalidRequest }
        let firstFrameDeadline = Task { [delay] in
            try? await delay(.seconds(LocalAPIContract.timeout))
            guard !Task.isCancelled else { return }
            connection.cancel()
        }
        defer { firstFrameDeadline.cancel() }
        let data = try await Self.readFrame(connection, maximum: LocalAPIContract.maximumRequestBytes)
        firstFrameDeadline.cancel()
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
                additions: [
                    "connectionID": grant.id.uuidString.lowercased(),
                    "macName": macName,
                ]
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
        responseProgress: ResponseProgress
    ) async throws {
        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        var offset = 0
        while offset < frame.count {
            let end = min(offset + 16 * 1024, frame.count)
            let chunk = frame[offset..<end]
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
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= maximum else { throw LocalAPIError.requestTooLarge }
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
        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: frame,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
    }

    private static func pairingReply(status: String, additions: [String: String] = [:]) -> Data {
        var object = ["v": 1, "status": status] as [String: Any]
        object.merge(additions) { _, new in new }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
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

    private static func argumentsAreValid(_ request: LocalAPIRequest, operation: LocalAPIOperation) -> Bool {
        if operation == .attentionEvents {
            return request.paneID == nil && request.targetVersion == nil && request.source == nil
                && (request.limit ?? 0) > 0
                && (request.limit ?? 0) <= LocalAPIContract.maximumAttentionPageSize
                && (request.cursor.map { !$0.isEmpty && $0.utf8.count <= 2048 } ?? true)
        }
        return request.paneID == nil && request.targetVersion == nil && request.source == nil
            && request.limit == nil && request.cursor == nil
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
            guard connection.companion?.transport == address.transport else { return nil }
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
