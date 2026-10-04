import Darwin
import Foundation

public final class LocalAPIServer: @unchecked Sendable {
    public typealias Capture =
        @MainActor @Sendable (
            LocalAPIRequest,
            UUID,
            LocalAPIAuthorizationLease
        ) async -> LocalAPIResponse
    private let endpoint: LocalAPIEndpoint
    public let instanceID = UUID()
    private let authorization: LocalAPIAuthorizationProvider
    private let capture: Capture
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private var started = false
    private var clients: [Int32: ClientState] = [:]
    private var pendingCaptures = 0
    private let acceptSource: DispatchSourceRead
    private let workers = DispatchGroup()

    public init(
        profile: String,
        authorization: LocalAPIAuthorizationProvider = .disabled,
        capture: @escaping Capture
    ) throws {
        let endpoint = try LocalAPIEndpoint(profile: profile, create: true)
        self.endpoint = endpoint
        self.authorization = authorization
        self.capture = capture
        var initialized = false
        defer {
            if !initialized {
                endpoint.cleanup()
                endpoint.releaseOwnership()
            }
        }
        try endpoint.takeOwnership()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalAPIError.transportFailure }
        do {
            try LocalAPIIO.configure(fd)
            var address = try endpoint.address()
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw LocalAPIError.transportFailure }
            // The enclosing directory is private before the socket becomes visible.
            try endpoint.recordSocket()
            guard listen(fd, Int32(LocalAPIContract.maximumClients)) == 0 else { throw LocalAPIError.transportFailure }
        } catch {
            close(fd)
            throw error
        }
        listener = fd
        let queue = DispatchQueue(label: "awesomux.local-api.accept", qos: .utility)
        acceptSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        acceptSource.setEventHandler { [weak self] in self?.acceptClients() }
        let group = workers
        let ownedEndpoint = endpoint
        acceptSource.setCancelHandler {
            group.wait()
            ownedEndpoint.cleanup()
            ownedEndpoint.releaseOwnership()
            close(fd)
        }
        initialized = true
    }

    deinit { stop() }

    public func start() {
        let shouldStart = lock.withLock {
            guard !started, !stopped else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        acceptSource.resume()
    }

    public func stop() {
        let shouldResume = lock.withLock {
            stopped = true
            for fd in clients.keys { shutdown(fd, SHUT_RDWR) }
            if !started {
                started = true
                return true
            }
            return false
        }
        acceptSource.cancel()
        if shouldResume { acceptSource.resume() }
    }

    public func invalidate(connectionID: UUID? = nil) {
        lock.withLock {
            for (fd, state) in clients where connectionID == nil || state.connectionID == connectionID {
                shutdown(fd, SHUT_RDWR)
            }
        }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func acceptClients() {
        // Yield the queue under continuous admission pressure so cancellation
        // and other work are not starved by a flood of immediately-ready peers.
        for _ in 0..<16 {
            guard !isStopped else { return }
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            do {
                try LocalAPIIO.configure(fd)
                try LocalAPIIO.validatePeer(fd)
            } catch {
                close(fd)
                continue
            }
            let admitted = lock.withLock {
                guard !stopped, clients.count < LocalAPIContract.maximumClients else { return false }
                clients[fd] = ClientState()
                return true
            }
            guard admitted else {
                close(fd)
                continue
            }
            workers.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                defer {
                    lock.withLock {
                        clients.removeValue(forKey: fd)
                        close(fd)
                    }
                    workers.leave()
                }
                serve(fd)
            }
        }
    }

    private func serve(_ fd: Int32) {
        let deadline = ContinuousClock.now.advanced(by: .seconds(LocalAPIContract.timeout))
        let io = LocalAPIIO(deadline: deadline, cancelled: { [self] in isStopped })
        var requestID: UUID?
        var responseBytesWritten = 0
        do {
            let data = try io.readFrame(fd, maximum: LocalAPIContract.maximumRequestBytes, oversized: .requestTooLarge)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                Set(object.keys).isSubset(of: [
                    "schemaVersion", "requestID", "profile", "operation", "connectionID", "credential", "paneID", "targetVersion", "limit",
                    "source",
                ]),
                let request = try? LocalAPIContract.decoder().decode(LocalAPIRequest.self, from: data)
            else { throw LocalAPIError.invalidRequest }
            requestID = request.requestID
            guard request.schemaVersion == LocalAPIContract.version else { throw LocalAPIError.unsupportedVersion }
            guard request.profile == endpoint.profile else { throw LocalAPIError.profileMismatch }
            guard LocalAPIOperation(rawValue: request.operation) != nil else { throw LocalAPIError.unsupportedOperation }
            if request.operation == LocalAPIOperation.agentContext.rawValue {
                guard request.paneID != nil, request.targetVersion != nil,
                    request.source != nil, let limit = request.limit, limit > 0
                else { throw LocalAPIError.invalidRequest }
            } else {
                guard request.paneID == nil, request.targetVersion == nil,
                    request.source == nil, request.limit == nil
                else { throw LocalAPIError.invalidRequest }
            }
            let lease = try authorization.authorize(request).get()
            lock.withLock { clients[fd]?.connectionID = lease.connectionID }
            let peerFD = dup(fd)
            guard peerFD >= 0 else { throw LocalAPIError.transportFailure }
            guard fcntl(peerFD, F_SETFD, FD_CLOEXEC) == 0 else {
                close(peerFD)
                throw LocalAPIError.transportFailure
            }
            let reserved = lock.withLock {
                guard !stopped, pendingCaptures < LocalAPIContract.maximumClients else { return false }
                pendingCaptures += 1
                return true
            }
            guard reserved else {
                close(peerFD)
                throw LocalAPIError.endpointBusy
            }
            let box = CaptureBox()
            let captureTask = Task { @MainActor [self] in
                defer { lock.withLock { pendingCaptures -= 1 } }
                guard box.isActive, !isStopped else { return }
                let response: LocalAPIResponse
                switch authorization.authorize(request, matching: lease) {
                case .failure(let denied):
                    response = LocalAPIResponse(requestID: request.requestID, error: denied)
                case .success:
                    response = await capture(request, instanceID, lease)
                }
                box.complete(response)
            }
            let peer = DispatchSource.makeReadSource(fileDescriptor: peerFD, queue: .global(qos: .utility))
            peer.setEventHandler {
                var byte: UInt8 = 0
                let peek = recv(peerFD, &byte, 1, MSG_PEEK)
                if peek >= 0 {
                    box.fail(peek == 0 ? .cancelled : .invalidRequest)
                    captureTask.cancel()
                }
            }
            peer.setCancelHandler { close(peerFD) }
            peer.resume()
            defer {
                peer.cancel()
                box.cancel()
                captureTask.cancel()
            }
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
            guard seconds > 0, box.ready.wait(timeout: .now() + seconds) == .success else {
                throw LocalAPIError.timeout
            }
            if let error = box.error { throw error }
            if isStopped { throw LocalAPIError.cancelled }
            guard let response = box.response else { throw LocalAPIError.cancelled }
            var encoded = try LocalAPIContract.encoder().encode(response)
            if encoded.count > LocalAPIContract.maximumResponseBytes {
                encoded = try LocalAPIContract.encoder().encode(LocalAPIResponse(requestID: requestID, error: .responseTooLarge))
            }
            let frame = LocalAPIIO.frame(encoded)
            var offset = 0
            while offset < frame.count {
                try io.wait(fd, events: Int16(POLLOUT))
                let currentOffset = offset
                let written = try authorization.commit(request, lease: lease) {
                    try LocalAPIIO.writeNonblockingChunk(fd, frame: frame, offset: currentOffset)
                }
                offset += written
                responseBytesWritten += written
            }
        } catch {
            guard !isStopped, responseBytesWritten == 0,
                let data = try? LocalAPIContract.encoder().encode(
                    LocalAPIResponse(requestID: requestID, error: (error as? LocalAPIError) ?? .transportFailure)
                )
            else { return }
            // A fresh short deadline allows a typed timeout reply without extending
            // a stalled client's original admission indefinitely.
            let replyIO = LocalAPIIO(deadline: .now.advanced(by: .milliseconds(100)), cancelled: { [self] in isStopped })
            try? replyIO.writeFrame(fd, data: data)
        }
    }
}

private struct ClientState {
    var connectionID: UUID?
}

private final class CaptureBox: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var active = true
    private var value: LocalAPIResponse?
    private var failure: LocalAPIError?
    var isActive: Bool { lock.withLock { active } }
    var response: LocalAPIResponse? { lock.withLock { value } }
    var error: LocalAPIError? { lock.withLock { failure } }
    func complete(_ response: LocalAPIResponse) {
        lock.withLock { if active { value = response } }
        ready.signal()
    }
    func fail(_ error: LocalAPIError) {
        lock.withLock {
            active = false
            failure = error
        }
        ready.signal()
    }
    func cancel() { lock.withLock { active = false } }
}
