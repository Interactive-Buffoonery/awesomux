import AwesoMuxCompanionProtocol
import AwesoMuxCore
import AwesoMuxLocalAPI
import Darwin
import Foundation
import Observation
import UnicodeHygiene

@MainActor
enum LocalPermissionPresentation {
    struct Context {
        let workspaceName: String
        let panePosition: Int

        init?(workspaceName: String, panePosition: Int) {
            let name = UnicodeHygiene.sanitize(workspaceName, maxLength: 80, stripInvisibleRoutingScalars: true)
            guard !name.isEmpty, panePosition > 0 else { return nil }
            self.workspaceName = name
            self.panePosition = panePosition
        }
    }

    static func isEligible(executionPlan: PaneExecutionPlan, compactTerminalKind: CompactTerminalKind?) -> Bool {
        executionPlan.remoteTarget == nil && compactTerminalKind == nil
    }

    static func context(for target: LocalPermissionTarget, in store: SessionStore) -> Context? {
        guard let session = store.session(id: target.workspaceID),
            let pane = session.layout.pane(id: target.paneID),
            isEligible(executionPlan: pane.executionPlan, compactTerminalKind: store.compactTerminalKind),
            let position = session.layout.paneIDs.firstIndex(of: target.paneID),
            let name = store.sidebarResolvedTitle(for: session.id)
        else { return nil }
        return Context(workspaceName: name, panePosition: position + 1)
    }
}

/// ADR-0028 local routing lane. It borrows the command bridge's secure socket
/// directory, but never enters its remote legacy connection/policy lane.
@MainActor @Observable
final class LocalPermissionCoordinator {
    struct Card: Equatable {
        let request: LocalPermissionRequest
        let outcome: LocalPermissionOutcome
    }
    private(set) var queuedCounts: [UUID: Int] = [:]
    private(set) var cards: [UUID: Card] = [:]
    private(set) var focusRequest: (paneID: UUID, token: UUID)?
    // Transport authority is retained only for the winning device answer.
    // Its closure holds the access-store lock across each actual output write.
    typealias RemoteAuthority = (() throws -> Void) throws -> Void
    @ObservationIgnored private var remoteAuthorities: [UUID: RemoteAuthority] = [:]
    @ObservationIgnored private let core = LocalPermissionDecisionCore()
    @ObservationIgnored private let runtimeID = UUID()
    @ObservationIgnored private let directoryScanCompleted: (LocalPermissionTarget) -> Void
    @ObservationIgnored private var endpoints: [UUID: LocalPermissionEndpoint] = [:]
    @ObservationIgnored private var endpointFiles: [UUID: URL] = [:]
    @ObservationIgnored private var eventFiles: [UUID: URL] = [:]
    @ObservationIgnored private var installedAt: [UUID: Date] = [:]
    @ObservationIgnored private var clients: [Int32: Client] = [:]
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var directory: BridgeListenerDirectory?
    @ObservationIgnored private var listener: Int32 = -1
    @ObservationIgnored private var fileRequests: Set<UUID> = []
    @ObservationIgnored private var displayedAt: [UUID: Date] = [:]
    @ObservationIgnored private var directoryWatches: [UUID: DispatchSourceFileSystemObject] = [:]
    @ObservationIgnored private var dirtyDirectories: Set<UUID> = []
    @ObservationIgnored private var scanTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastBackstop = Date.distantPast
    @ObservationIgnored private var publishedDecisions: [UUID: LocalPermissionState] = [:]
    @ObservationIgnored private var publicationAttempts: [UUID: (state: LocalPermissionState, count: Int, last: Date)] = [:]
    @ObservationIgnored private let announcement: (String) -> Void
    @ObservationIgnored private var presentationContexts: [UUID: (LocalPermissionTarget) -> LocalPermissionPresentation.Context?] = [:]
    @ObservationIgnored private var invocationNumbers: [UUID: Int] = [:]
    @ObservationIgnored private var nextInvocationNumber = 1
    @ObservationIgnored private var announcedStates: [UUID: LocalPermissionState] = [:]

    private struct Client {
        var bytes = Data()
        var request: LocalPermissionRequest?
        var sent = false
        let connectedAt = Date()
    }

    init(
        directoryScanCompleted: @escaping (LocalPermissionTarget) -> Void = { _ in },
        announcement: @escaping (String) -> Void = { TerminalAccessibilityAnnouncer.announce($0) }
    ) {
        self.directoryScanCompleted = directoryScanCompleted
        self.announcement = announcement
        if let directory = try? BridgeListenerDirectory.create(socketName: "local-permission.sock"),
            var address = LocalPermissionFiles.address(directory.socketPath)
        {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            if fd >= 0 {
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                if result == 0, chmod(directory.socketPath, 0o600) == 0,
                    Darwin.listen(fd, 16) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
                    fcntl(fd, F_SETFD, FD_CLOEXEC) == 0
                {
                    self.directory = directory
                    listener = fd
                } else {
                    close(fd)
                }
            }
            if self.directory == nil {
                unlink(directory.socketPath)
                rmdir(directory.directoryPath)
            }
        }
    }

    isolated deinit {
        timer?.cancel()
        for source in directoryWatches.values { source.cancel() }
        for task in scanTasks.values { task.cancel() }
        for fd in clients.keys { close(fd) }
        if listener >= 0 { close(listener) }
        if let directory { unlink(directory.socketPath); rmdir(directory.directoryPath) }
        for file in endpointFiles.values { unlink(file.path) }
        for endpoint in endpoints.values { try? FileManager.default.removeItem(atPath: endpoint.directory) }
    }

    func install(
        workspaceID: UUID, paneID: UUID, eventFile: URL,
        presentationContext: @escaping (LocalPermissionTarget) -> LocalPermissionPresentation.Context? = { _ in nil }
    ) -> LocalPermissionEndpoint? {
        retire(paneID: paneID)
        let target = LocalPermissionTarget(runtimeID: runtimeID, workspaceID: workspaceID, paneID: paneID, version: UUID())
        let path = eventFile.deletingLastPathComponent().appendingPathComponent("permissions-\(target.version.uuidString)").path
        guard mkdir(path, 0o700) == 0 else { return nil }
        let endpoint = LocalPermissionEndpoint(target: target, directory: path, socket: directory?.socketPath)
        // The stable descriptor path reaches already-running daemon shells.
        // Each fresh helper reads the current target; an in-flight helper keeps
        // its original snapshot and cannot migrate authority across restarts.
        let descriptor = LocalPermissionEndpoint.environmentFile(for: eventFile)
        unlink(descriptor.path)
        guard LocalPermissionFiles.write(endpoint, at: descriptor) else {
            try? FileManager.default.removeItem(atPath: path)
            return nil
        }
        endpointFiles[paneID] = descriptor
        eventFiles[paneID] = eventFile
        endpoints[paneID] = endpoint
        presentationContexts[paneID] = presentationContext
        installedAt[paneID] = Date()
        core.install(target)
        watchDirectory(endpoint)
        dirtyDirectories.insert(paneID)
        if timer == nil {
            let source = DispatchSource.makeTimerSource(queue: .main)
            source.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(20))
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.pump() }
            }
            timer = source
            source.resume()
        }
        return endpoint
    }

    /// A surviving shell reads this same descriptor for each new invocation.
    /// Its event stream stays installed; only permission authority is renewed.
    func move(paneID: UUID, to workspaceID: UUID) {
        guard let endpoint = endpoints[paneID], endpoint.target.workspaceID != workspaceID,
            let eventFile = eventFiles[paneID], let presentationContext = presentationContexts[paneID]
        else { return }
        _ = install(workspaceID: workspaceID, paneID: paneID, eventFile: eventFile, presentationContext: presentationContext)
    }

    func retire(paneID: UUID) {
        guard let endpoint = endpoints.removeValue(forKey: paneID) else { return }
        directoryWatches.removeValue(forKey: paneID)?.cancel()
        scanTasks.removeValue(forKey: paneID)?.cancel()
        dirtyDirectories.remove(paneID)
        core.retire(endpoint.target)
        presentationContexts.removeValue(forKey: paneID)
        if let file = endpointFiles.removeValue(forKey: paneID) { unlink(file.path) }
        installedAt.removeValue(forKey: paneID)
        eventFiles.removeValue(forKey: paneID)
        for (fd, client) in clients where client.request?.target == endpoint.target { disconnect(fd) }
        try? FileManager.default.removeItem(atPath: endpoint.directory)
        cards.removeValue(forKey: paneID)
        queuedCounts.removeValue(forKey: paneID)
        if endpoints.isEmpty { timer?.cancel(); timer = nil }
    }

    func retireAll() { for pane in Array(endpoints.keys) { retire(paneID: pane) } }

    func observe(_ event: AgentRuntimeEvent, paneID: UUID) {
        guard event.source == .claudeCode, let endpoint = endpoints[paneID],
            let timestamp = event.timestamp, timestamp >= (installedAt[paneID] ?? .distantFuture),
            timestamp <= Date().addingTimeInterval(5),
            let session = event.providerSessionID
        else { return }
        if event.phase == .sessionStart {
            core.observeSession(session, target: endpoint.target, at: timestamp)
            // Session evidence can make an unchanged rejected fallback eligible.
            // Re-admission still checks the original identity, expiry and fences.
            dirtyDirectories.insert(paneID)
        }
        // Session lifecycle/progress is conservative invalidation, never proof of
        // provider completion. Tool progress additionally needs an exact native
        // ID; Claude PermissionRequest normally omits tool_use_id. Attention
        // heuristics, terminal text and silence never cancel or create authority.
        if event.phase == .sessionEnd || event.phase == .promptSubmit || event.phase == .stop {
            core.observeProgress(session: session, target: endpoint.target, at: timestamp)
        } else if event.phase == .toolEnd, let toolID = event.eventID {
            core.observeProgress(session: session, target: endpoint.target, at: timestamp, toolUseID: toolID)
        }
        publish()
    }

    func requestFocus(paneID: UUID) {
        guard cards[paneID]?.outcome.state == .pending else { return }
        focusRequest = (paneID, UUID())
    }

    func decide(_ identity: LocalPermissionIdentity, choice: LocalPermissionChoice) {
        guard let card = cards[identity.target.paneID], card.request.identity == identity,
            Date().timeIntervalSince(displayedAt[identity.invocationID] ?? .distantFuture) >= 0.35
        else { return }
        _ = core.commit(identity, choice: choice, now: Date(), helperAlive: LocalPermissionFiles.helperAlive(card.request))
        publish()  // Preserve the recorded transition before delivery can coalesce it.
        pump()
    }

    /// No provider/version has passed ADR-0038's interactive native-prompt
    /// races. This is deliberately not controlled by preferences or E2E flags.
    static func remoteDecisionsEnabled(provider: String, version: String?) -> Bool { false }

    func remoteResponse(
        answer: CompanionDecisionAnswer?, deviceID: UUID, deviceName: String,
        authorize: @escaping RemoteAuthority,
        eligible: @escaping (LocalPermissionTarget) -> Bool,
        fixture: Bool = false
    ) throws -> (pending: [CompanionPendingDecision], outcomes: [CompanionDecisionReceipt], receipt: CompanionDecisionReceipt?) {
        let enabled = Self.remoteDecisionsEnabled(provider: "claudeCode", version: nil)
        #if DEBUG
            // Only an isolated synthetic coordinator uses the fixture path.
            guard enabled || fixture else { throw LocalAPIError.permissionDenied }
        #else
            guard enabled else { throw LocalAPIError.permissionDenied }
        #endif
        core.sweep(now: Date())
        let allowed: (LocalPermissionTarget) -> Bool = { [weak self] target in
            self?.endpoints[target.paneID]?.target == target && eligible(target)
        }
        var receipt: CompanionDecisionReceipt?
        try authorize {
            if let answer {
                let identity = answer.identity.localIdentity
                guard allowed(identity.target) else { throw LocalAPIError.permissionDenied }
                let request = core.requests.first { $0.identity == identity }
                let result = core.commitRemote(
                    identity, choice: answer.choice == .allow ? .allow : .deny,
                    deviceID: deviceID, deviceName: deviceName, retryID: answer.retryID, now: Date(),
                    helperAlive: request.map(LocalPermissionFiles.helperAlive) ?? false)
                if result.result == .recorded, remoteAuthorities[identity.invocationID] == nil {
                    remoteAuthorities[identity.invocationID] = { body in
                        guard allowed(identity.target) else { throw LocalAPIError.permissionDenied }
                        try authorize(body)
                    }
                }
                receipt = Self.wireReceipt(identity: identity, result: result.result, outcome: result.outcome)
            }
        }
        let requests = core.requests.filter { allowed($0.target) }
        for request in requests {
            core.validate(request.identity, now: Date(), helperAlive: LocalPermissionFiles.helperAlive(request))
        }
        let pending = requests.compactMap { request -> CompanionPendingDecision? in
            guard core.outcome(request.identity)?.state == .pending,
                let deadline = core.remoteExpiry(request.identity), deadline > Date()
            else { return nil }
            return CompanionPendingDecision(
                identity: request.identity.companionIdentity, tool: request.tool, summary: request.summary,
                remoteExpiresAt: deadline, choices: request.choices.map { $0 == .allow ? .allow : .deny })
        }.sorted { $0.remoteExpiresAt < $1.remoteExpiresAt }
        let outcomes = requests.compactMap { request -> CompanionDecisionReceipt? in
            guard let outcome = core.outcome(request.identity), outcome.state != .pending else { return nil }
            return Self.wireReceipt(identity: request.identity, result: .alreadyAnswered, outcome: outcome)
        }
        publish()
        return (pending, outcomes, receipt)
    }

    func validateRemoteTargets(_ identities: [CompanionDecisionIdentity], eligible: (LocalPermissionTarget) -> Bool)
        throws
    {
        for identity in identities {
            let target = identity.localIdentity.target
            guard endpoints[target.paneID]?.target == target, eligible(target) else {
                throw LocalAPIError.permissionDenied
            }
        }
    }

    private static func wireReceipt(
        identity: LocalPermissionIdentity, result: LocalPermissionRemoteReceipt.Result, outcome: LocalPermissionOutcome?
    )
        -> CompanionDecisionReceipt
    {
        let wireResult: CompanionDecisionReceipt.Result =
            switch result {
            case .recorded: .recorded
            case .alreadyAnswered: .alreadyAnswered
            case .expired: .expired
            case .unknown: .unknown
            case .retryConflict: .retryConflict
            case .capacityExceeded: .capacityExceeded
            }
        return .init(
            identity: identity.companionIdentity,
            result: wireResult,
            state: outcome.flatMap { CompanionDecisionState(rawValue: $0.state.rawValue) } ?? .unknown,
            choice: outcome?.choice.flatMap { CompanionDecisionChoice(rawValue: $0.rawValue) },
            source: outcome?.source.map {
                switch $0 {
                case .mac: CompanionDecisionSource(name: "Mac")
                case .device(let id, let name): CompanionDecisionSource(deviceID: id, name: name)
                }
            })
    }

    private func refreshRemoteAuthority(_ identity: LocalPermissionIdentity) {
        guard let outcome = core.outcome(identity), case .device? = outcome.source,
            [.pending, .recorded, .delivering].contains(outcome.state)
        else { return }
        do {
            guard let authorize = remoteAuthorities[identity.invocationID] else { throw LocalAPIError.permissionDenied }
            try authorize {}
        } catch { core.cancel(identity) }
    }

    private func withDeliveryAuthority(
        _ identity: LocalPermissionIdentity, body: (LocalPermissionOutcome) throws -> Void
    ) -> Bool {
        func writeCurrentOutcome() throws {
            guard endpoints[identity.target.paneID]?.target == identity.target,
                var wire = core.outcome(identity), wire.state != .pending, wire.state != .recorded
            else { throw LocalAPIError.permissionDenied }
            // Build the wire value at the write boundary. A failed authorization
            // must never leave a captured delivering choice available to send.
            if wire.state == .delivering {
                core.markOutputAttempted(identity)
            } else {
                wire.choice = nil
            }
            try body(wire)
        }
        do {
            if let outcome = core.outcome(identity), outcome.state == .delivering,
                outcome.choice != nil, case .device? = outcome.source
            {
                guard let authorize = remoteAuthorities[identity.invocationID] else { throw LocalAPIError.permissionDenied }
                try authorize { try writeCurrentOutcome() }
            } else {
                // Choice-free terminal replies wake the exact hook even after
                // its winning device loses access. They confer no authority.
                try writeCurrentOutcome()
            }
            return true
        } catch {
            core.cancel(identity)
            return false
        }
    }

    #if DEBUG
        /// Synthetic hook ingress belongs to a dedicated coordinator, never the
        /// runtime's real provider coordinator. No helper consumes these targets.
        func seedRemoteFixture(workspaceID: UUID, paneID: UUID, eventFile: URL, expiresIn: TimeInterval) throws -> LocalPermissionIdentity {
            let current = endpoints[paneID].flatMap { $0.target.workspaceID == workspaceID ? $0 : nil }
            guard let endpoint = current ?? install(workspaceID: workspaceID, paneID: paneID, eventFile: eventFile),
                let started = LocalPermissionFiles.processStartMicroseconds(getpid())
            else { throw LocalAPIError.appUnavailable }
            let request = LocalPermissionRequest(
                target: endpoint.target, providerSessionID: "synthetic-pairing-fixture",
                invocationID: UUID(), toolUseID: nil, helperPID: getpid(), helperStartMicroseconds: started,
                expiresAt: Date().addingTimeInterval(expiresIn), tool: "Fixture", summary: "Synthetic decision; no provider tool")
            guard core.admit(request, now: Date(), helperAlive: true) else { throw LocalAPIError.appUnavailable }
            return request.identity
        }
    #endif

    private func verified(_ request: LocalPermissionRequest) -> Bool {
        endpoints[request.target.paneID]?.target == request.target
            && core.admit(request, now: Date(), helperAlive: LocalPermissionFiles.helperAlive(request))
    }

    private func pump() {
        core.sweep(now: Date())
        let retainedIDs = Set(core.requests.map(\.invocationID))
        remoteAuthorities = remoteAuthorities.filter { retainedIDs.contains($0.key) }
        acceptClients()
        for fd in Array(clients.keys) { readClient(fd) }
        if Date().timeIntervalSince(lastBackstop) >= 5 {
            lastBackstop = Date()
            for paneID in endpoints.keys where directoryWatches[paneID] == nil {
                dirtyDirectories.insert(paneID)
            }
        }
        for paneID in Array(dirtyDirectories) where scanTasks.count < 4 && scanTasks[paneID] == nil {
            if let endpoint = endpoints[paneID] { scheduleScan(endpoint) }
        }
        for request in core.requests {
            let identity = request.identity
            guard let endpoint = endpoints[request.target.paneID], endpoint.target == request.target else { continue }
            guard let state = core.outcome(identity)?.state else { continue }
            let active = state == .pending || state == .recorded || state == .delivering
            let usesFiles = fileRequests.contains(request.invocationID)
            if active {
                if usesFiles {
                    // A helper may exit immediately after its successful stdout/ACK.
                    // Consume that receipt before considering exit or removed req.
                    if let ack = LocalPermissionFiles.read(
                        LocalPermissionIdentity.self, at: endpoint.file("ack", id: request.invocationID)),
                        ack == identity
                    {
                        core.acknowledge(identity)
                    }
                    // A receipt closes active servicing immediately.
                    if core.outcome(identity)?.state != .delivered {
                        let alive = LocalPermissionFiles.helperAlive(request)
                        let reqURL = endpoint.file("req", id: request.invocationID)
                        if !alive || LocalPermissionFiles.read(LocalPermissionRequest.self, at: reqURL) == nil {
                            core.cancel(identity)
                        }
                        if core.outcome(identity)?.state == .recorded {
                            _ = core.claimDelivery(identity, now: Date(), helperAlive: alive)
                        }
                    }
                } else if !LocalPermissionFiles.helperAlive(request) {
                    core.cancel(identity)
                }
                refreshRemoteAuthority(identity)
            }
            // Retained outcomes do not service receipts or liveness. Publication
            // has its own bounded retry budget even after a terminal transition.
            if usesFiles, let outcome = core.outcome(identity), outcome.state != .pending && outcome.state != .recorded {
                publishDecision(outcome, endpoint: endpoint)
            }
        }
        for fd in Array(clients.keys) { deliver(fd) }
        publish()
    }

    private func acceptClients() {
        guard listener >= 0 else { return }
        for _ in 0..<16 {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { break }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard clients.count < 32, getpeereid(fd, &uid, &gid) == 0, uid == geteuid(),
                fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
                fcntl(fd, F_SETFD, FD_CLOEXEC) == 0
            else { close(fd); continue }
            var noSignal: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            clients[fd] = Client()
        }
    }

    private func readClient(_ fd: Int32) {
        guard var client = clients[fd] else { return }
        if Date().timeIntervalSince(client.connectedAt) > (client.request == nil ? 2 : 125) { disconnect(fd); return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        let count = recv(fd, &bytes, bytes.count, 0)
        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { return }
        guard count > 0 else { disconnect(fd); return }
        client.bytes.append(contentsOf: bytes.prefix(count))
        guard client.bytes.count <= LocalPermissionFiles.maximumBytes else { disconnect(fd); return }
        if let newline = client.bytes.firstIndex(of: 10) {
            let line = Data(client.bytes[..<newline])
            client.bytes.removeSubrange(...newline)
            if let request = client.request {
                guard client.sent,
                    let ack = try? JSONDecoder().decode(LocalPermissionIdentity.self, from: line), ack == request.identity
                else {
                    disconnect(fd); return
                }
                core.acknowledge(ack)
                clients[fd] = client
                disconnect(fd)
                return
            }
            guard let request = try? JSONDecoder().decode(LocalPermissionRequest.self, from: line), verified(request) else {
                disconnect(fd); return
            }
            client.request = request
        }
        clients[fd] = client
    }

    private func deliver(_ fd: Int32) {
        guard var client = clients[fd], !client.sent, let request = client.request else { return }
        let identity = request.identity
        if core.outcome(identity)?.state == .recorded {
            _ = core.claimDelivery(identity, now: Date(), helperAlive: LocalPermissionFiles.helperAlive(request))
        }
        guard let outcome = core.outcome(identity), outcome.state != .pending else { return }
        // A second connection or fallback cannot retrieve an answer after the
        // first transport claimed it. Only the claiming fd may write it below.
        if outcome.state == .delivering {
            guard !clients.contains(where: { $0.key != fd && $0.value.request?.identity == identity && $0.value.sent }),
                !fileRequests.contains(request.invocationID)
            else { return }
        }
        var count = -1
        var expectedCount = 0
        guard
            withDeliveryAuthority(
                identity,
                body: { wire in
                    var data = try JSONEncoder().encode(wire)
                    data.append(10)
                    expectedCount = data.count
                    count = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
                })
        else { return }
        guard count == expectedCount else { core.deliveryLost(identity); disconnect(fd); return }
        client.sent = true
        clients[fd] = client
    }

    private func disconnect(_ fd: Int32) {
        if let client = clients.removeValue(forKey: fd), client.sent, let request = client.request {
            core.deliveryLost(request.identity)
        }
        close(fd)
    }

    private func watchDirectory(_ endpoint: LocalPermissionEndpoint) {
        let fd = open(endpoint.directory, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        guard BridgeListenerDirectory.isSecureDirectory(at: endpoint.directory) else { close(fd); return }
        let paneID = endpoint.target.paneID
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated {
                guard let self, let source, self.endpoints[paneID]?.target == endpoint.target,
                    self.directoryWatches[paneID] === source
                else { return }
                self.dirtyDirectories.insert(paneID)
                if source.data.contains(.delete) || source.data.contains(.rename) {
                    self.directoryWatches.removeValue(forKey: paneID)?.cancel()
                }
            }
        }
        directoryWatches[paneID] = source
        source.resume()
    }

    private func scheduleScan(_ endpoint: LocalPermissionEndpoint) {
        let paneID = endpoint.target.paneID
        dirtyDirectories.remove(paneID)
        scanTasks[paneID] = Task { [weak self] in
            let files = await Task.detached(priority: .utility) {
                (try? FileManager.default.contentsOfDirectory(atPath: endpoint.directory)) ?? []
            }.value
            guard !Task.isCancelled, let self, self.endpoints[paneID]?.target == endpoint.target else { return }
            self.scanTasks.removeValue(forKey: paneID)
            let retainedIDs = Set(self.core.requests.map(\.invocationID))
            for name in files.filter({ $0.hasPrefix("dec-") || $0.hasPrefix("ack-") }).prefix(512) {
                let rawID = String(name.dropFirst(4).dropLast(5))
                if let id = UUID(uuidString: rawID), !retainedIDs.contains(id) {
                    unlink(URL(fileURLWithPath: endpoint.directory).appendingPathComponent(name).path)
                }
            }
            for name in files.filter({ $0.hasPrefix("req-") && $0.hasSuffix(".json") }).prefix(128) {
                let url = URL(fileURLWithPath: endpoint.directory).appendingPathComponent(name)
                guard let request = LocalPermissionFiles.read(LocalPermissionRequest.self, at: url),
                    name == "req-\(request.invocationID.uuidString).json", request.target == endpoint.target,
                    self.verified(request)
                else { continue }
                self.fileRequests.insert(request.invocationID)
            }
            self.directoryScanCompleted(endpoint.target)
            self.pump()
        }
    }

    private func publishDecision(_ outcome: LocalPermissionOutcome, endpoint: LocalPermissionEndpoint) {
        let id = outcome.identity.invocationID
        guard publishedDecisions[id] != outcome.state else { return }
        let prior = publicationAttempts[id]
        let attempt = prior?.state == outcome.state ? prior : nil
        guard (attempt?.count ?? 0) < 5, Date().timeIntervalSince(attempt?.last ?? .distantPast) >= 1 else { return }
        let file = endpoint.file("dec", id: id)
        if let existing = LocalPermissionFiles.read(LocalPermissionOutcome.self, at: file), existing.identity == outcome.identity,
            existing.state == outcome.state, existing.choice == (outcome.state == .delivering ? outcome.choice : nil)
        {
            publishedDecisions[id] = outcome.state
            return
        }
        // A terminal transition gets its own bounded publication attempts and
        // replaces an earlier escaped choice with the current choice-free state.
        publicationAttempts[id] = (outcome.state, (attempt?.count ?? 0) + 1, Date())
        var wrote = false
        var writtenState: LocalPermissionState?
        guard
            withDeliveryAuthority(
                outcome.identity,
                body: { wire in
                    wrote = LocalPermissionFiles.write(wire, at: file)
                    if !wrote, wire.state != .delivering {
                        wrote = LocalPermissionFiles.replaceWithTerminalOutcome(wire, at: file)
                    }
                    writtenState = wire.state
                })
        else { return }
        if wrote {
            publishedDecisions[id] = writtenState
        } else if publicationAttempts[id]?.count == 5 {
            core.deliveryLost(outcome.identity)
        }
    }

    static func recordedMessage(_ outcome: LocalPermissionOutcome) -> String {
        if case .device(_, let name)? = outcome.source {
            return outcome.choice == .allow
                ? String(
                    localized: "Allow once recorded on paired device \(name)",
                    comment: "A named paired device recorded an allow; provider execution is unconfirmed.")
                : String(
                    localized: "Deny once recorded on paired device \(name)",
                    comment: "A named paired device recorded a deny; provider execution is unconfirmed.")
        }
        return outcome.choice == .allow
            ? String(
                localized: "Allow once recorded on Mac",
                comment: "The Mac recorded a one-time allow; delivery to the hook is not yet confirmed.")
            : String(
                localized: "Deny once recorded on Mac",
                comment: "The Mac recorded a one-time deny; delivery to the hook is not yet confirmed.")
    }

    private func announce(_ outcome: LocalPermissionOutcome) {
        guard let context = presentationContexts[outcome.identity.target.paneID]?(outcome.identity.target),
            let invocationNumber = invocationNumbers[outcome.identity.invocationID]
        else { return }
        let message: String
        switch outcome.state {
        case .pending:
            message = String(
                localized: "Claude permission needed", comment: "A local Claude hook is waiting for a one-time permission decision.")
        case .recorded:
            message = Self.recordedMessage(outcome)
        case .delivered:
            message = String(
                localized: "Answer delivered to Claude hook. Tool execution is unconfirmed.",
                comment: "Permission announcement after hook acknowledgement; delivery does not confirm tool execution.")
        case .unknown:
            message = String(
                localized: "Permission delivery unknown",
                comment: "Delivery of the recorded decision is uncertain; do not retry or imply tool execution.")
        case .expired:
            message = String(
                localized: "Permission request expired",
                comment: "The local permission request expired; the hook falls through to the native prompt.")
        case .cancelled:
            message = String(
                localized: "Permission request cancelled",
                comment: "The local permission request was cancelled and cannot receive another decision.")
        case .delivering: return
        }
        announcement(
            String(
                localized: "\(context.workspaceName), pane \(context.panePosition), request \(invocationNumber). \(message)",
                comment:
                    "Permission announcement: workspace name, one-based pane position, stable request number, then decision or delivery state."
            ))
    }

    private func publish() {
        var next: [UUID: Card] = [:]
        for request in core.requests.sorted(by: { $0.expiresAt > $1.expiresAt }) {
            guard endpoints[request.target.paneID]?.target == request.target,
                let outcome = core.outcome(request.identity)
            else { continue }
            // Keep the label stable even if another invocation arrives later.
            if invocationNumbers[request.invocationID] == nil {
                invocationNumbers[request.invocationID] = nextInvocationNumber
                nextInvocationNumber += 1
            }
            if announcedStates[request.invocationID] != outcome.state {
                announce(outcome)
                announcedStates[request.invocationID] = outcome.state
            }
            if outcome.state != .pending, next[request.target.paneID] == nil {
                next[request.target.paneID] = Card(request: request, outcome: outcome)
            }
        }
        var counts: [UUID: Int] = [:]
        // The oldest pending hook owns the card. An arrival never displaces it.
        for request in core.pendingRequests {
            let pane = request.target.paneID
            counts[pane, default: 0] += 1
            if next[pane]?.outcome.state != .pending, let outcome = core.outcome(request.identity) {
                next[pane] = Card(request: request, outcome: outcome)
            }
        }
        let queued = counts.mapValues { max(0, $0 - 1) }
        if queuedCounts != queued { queuedCounts = queued }
        for (pane, card) in next where cards[pane]?.request.identity != card.request.identity {
            displayedAt[card.request.invocationID] = Date()
        }
        if cards != next { cards = next }
        let retained = Set(core.requests.map(\.invocationID))
        fileRequests.formIntersection(retained)
        publishedDecisions = publishedDecisions.filter { retained.contains($0.key) }
        publicationAttempts = publicationAttempts.filter { retained.contains($0.key) }
        announcedStates = announcedStates.filter { retained.contains($0.key) }
        invocationNumbers = invocationNumbers.filter { retained.contains($0.key) }
        displayedAt = displayedAt.filter { retained.contains($0.key) }
    }
}

extension LocalPermissionIdentity {
    var companionIdentity: CompanionDecisionIdentity {
        .init(
            runtimeID: target.runtimeID, workspaceID: target.workspaceID, paneID: target.paneID,
            targetVersion: target.version, providerSessionID: providerSessionID, invocationID: invocationID, revision: revision)
    }
}
extension CompanionDecisionIdentity {
    var localIdentity: LocalPermissionIdentity {
        .init(
            target: .init(runtimeID: runtimeID, workspaceID: workspaceID, paneID: paneID, version: targetVersion),
            providerSessionID: providerSessionID, invocationID: invocationID, revision: revision)
    }
}
