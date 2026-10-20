import AwesoMuxCore
import Darwin
import Foundation
import Observation

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
    @ObservationIgnored private let core = LocalPermissionDecisionCore()
    @ObservationIgnored private let runtimeID = UUID()
    @ObservationIgnored private var endpoints: [UUID: LocalPermissionEndpoint] = [:]
    @ObservationIgnored private var endpointFiles: [UUID: URL] = [:]
    @ObservationIgnored private var installedAt: [UUID: Date] = [:]
    @ObservationIgnored private var clients: [Int32: Client] = [:]
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var directory: BridgeListenerDirectory?
    @ObservationIgnored private var listener: Int32 = -1
    @ObservationIgnored private var fileRequests: Set<UUID> = []
    @ObservationIgnored private var displayedAt: [UUID: Date] = [:]
    @ObservationIgnored private var directoryWatches: [UUID: DispatchSourceFileSystemObject] = [:]
    @ObservationIgnored private var dirtyDirectories: Set<UUID> = []
    @ObservationIgnored private var scanTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastBackstop = Date.distantPast
    @ObservationIgnored private var publishedDecisions: Set<UUID> = []
    @ObservationIgnored private var publicationAttempts: [UUID: (count: Int, last: Date)] = [:]
    @ObservationIgnored private var announcedStates: [UUID: LocalPermissionState] = [:]

    private struct Client {
        var bytes = Data()
        var request: LocalPermissionRequest?
        var sent = false
        let connectedAt = Date()
    }

    init() {
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

    func install(workspaceID: UUID, paneID: UUID, eventFile: URL) -> LocalPermissionEndpoint? {
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
        endpoints[paneID] = endpoint
        installedAt[paneID] = Date()
        core.install(target)
        watchDirectory(endpoint)
        dirtyDirectories.insert(paneID)
        if timer == nil {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self else { return }
                    self.pump()
                }
            }
        }
        return endpoint
    }

    func retire(paneID: UUID) {
        guard let endpoint = endpoints.removeValue(forKey: paneID) else { return }
        directoryWatches.removeValue(forKey: paneID)?.cancel()
        scanTasks.removeValue(forKey: paneID)?.cancel()
        dirtyDirectories.remove(paneID)
        core.retire(endpoint.target)
        if let file = endpointFiles.removeValue(forKey: paneID) { unlink(file.path) }
        installedAt.removeValue(forKey: paneID)
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

    private func verified(_ request: LocalPermissionRequest) -> Bool {
        endpoints[request.target.paneID]?.target == request.target
            && core.admit(request, now: Date(), helperAlive: LocalPermissionFiles.helperAlive(request))
    }

    private func pump() {
        core.sweep(now: Date())
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
            if fileRequests.contains(request.invocationID) {
                // A helper may exit immediately after its successful stdout/ACK.
                // Consume that receipt before considering exit or removed req.
                if let ack = LocalPermissionFiles.read(LocalPermissionIdentity.self, at: endpoint.file("ack", id: request.invocationID)),
                    ack == identity
                {
                    core.acknowledge(identity)
                }
                let reqURL = endpoint.file("req", id: request.invocationID)
                if !LocalPermissionFiles.helperAlive(request)
                    || LocalPermissionFiles.read(LocalPermissionRequest.self, at: reqURL) == nil
                {
                    core.cancel(request.identity)
                }
                if core.outcome(identity)?.state == .recorded {
                    _ = core.claimDelivery(identity, now: Date(), helperAlive: LocalPermissionFiles.helperAlive(request))
                }
                if let outcome = core.outcome(identity), outcome.state != .pending && outcome.state != .recorded {
                    publishDecision(outcome, endpoint: endpoint)
                }
            } else if !LocalPermissionFiles.helperAlive(request) {
                core.cancel(request.identity)
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
        guard var outcome = core.outcome(identity), outcome.state != .pending else { return }
        // A second connection or fallback cannot retrieve an answer after the
        // first transport claimed it. Only the claiming fd may write it below.
        if outcome.state == .delivering {
            guard !clients.contains(where: { $0.key != fd && $0.value.request?.identity == identity && $0.value.sent }),
                !fileRequests.contains(request.invocationID)
            else { return }
        } else {
            outcome.choice = nil
        }
        guard var data = try? JSONEncoder().encode(outcome) else { disconnect(fd); return }
        data.append(10)
        let count = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard count == data.count else { core.deliveryLost(identity); disconnect(fd); return }
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
            self.pump()
        }
    }

    private func publishDecision(_ outcome: LocalPermissionOutcome, endpoint: LocalPermissionEndpoint) {
        let id = outcome.identity.invocationID
        guard !publishedDecisions.contains(id) else { return }
        let file = endpoint.file("dec", id: id)
        if let existing = LocalPermissionFiles.read(LocalPermissionOutcome.self, at: file), existing.identity == outcome.identity {
            publishedDecisions.insert(id)
            return
        }
        let attempt = publicationAttempts[id]
        guard (attempt?.count ?? 0) < 5, Date().timeIntervalSince(attempt?.last ?? .distantPast) >= 1 else { return }
        var wire = outcome
        if wire.state != .delivering { wire.choice = nil }
        publicationAttempts[id] = ((attempt?.count ?? 0) + 1, Date())
        if LocalPermissionFiles.write(wire, at: file) {
            publishedDecisions.insert(id)
        } else if publicationAttempts[id]?.count == 5 {
            core.deliveryLost(outcome.identity)
        }
    }

    private func announce(_ outcome: LocalPermissionOutcome) {
        let message: String
        switch outcome.state {
        case .pending: message = String(localized: "Claude permission needed")
        case .recorded:
            message =
                outcome.choice == .allow ? String(localized: "Allow once recorded on Mac") : String(localized: "Deny once recorded on Mac")
        case .delivered: message = String(localized: "Answer delivered to Claude hook. Tool execution is unconfirmed.")
        case .unknown: message = String(localized: "Permission delivery unknown")
        case .expired: message = String(localized: "Permission request expired")
        case .cancelled: message = String(localized: "Permission request cancelled")
        case .delivering: return
        }
        TerminalAccessibilityAnnouncer.announce(message)
    }

    private func publish() {
        var next: [UUID: Card] = [:]
        for request in core.requests.sorted(by: { $0.expiresAt > $1.expiresAt }) {
            guard endpoints[request.target.paneID]?.target == request.target,
                let outcome = core.outcome(request.identity)
            else { continue }
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
        publishedDecisions.formIntersection(retained)
        publicationAttempts = publicationAttempts.filter { retained.contains($0.key) }
        announcedStates = announcedStates.filter { retained.contains($0.key) }
        displayedAt = displayedAt.filter { retained.contains($0.key) }
    }
}
