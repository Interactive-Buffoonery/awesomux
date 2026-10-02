import Darwin
import Foundation

public final class LocalAPIServer: @unchecked Sendable {
    public typealias Authorization = @Sendable (LocalAPIRequest) -> LocalAPIError?
    public typealias Capture = @MainActor @Sendable (LocalAPIRequest, UUID) async -> LocalAPIResponse
    private let endpoint: LocalAPIEndpoint
    public let instanceID = UUID()
    private let authorization: Authorization
    private let capture: Capture
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private var started = false
    private var clients = Set<Int32>()
    private var pendingCaptures = 0
    private let acceptSource: DispatchSourceRead
    private let workers = DispatchGroup()

    public init(profile: String, authorization: @escaping Authorization = { _ in .accessDisabled }, capture: @escaping Capture) throws {
        endpoint = try LocalAPIEndpoint(profile: profile, create: true)
        self.authorization = authorization
        self.capture = capture
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
            endpoint.cleanup()
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
            for fd in clients { shutdown(fd, SHUT_RDWR) }
            if !started {
                started = true
                return true
            }
            return false
        }
        acceptSource.cancel()
        if shouldResume { acceptSource.resume() }
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
                clients.insert(fd)
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
                        clients.remove(fd)
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
        do {
            let data = try io.readFrame(fd, maximum: LocalAPIContract.maximumRequestBytes, oversized: .requestTooLarge)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                Set(object.keys).isSubset(of: ["schemaVersion", "requestID", "profile", "operation", "credential"]),
                let request = try? LocalAPIContract.decoder().decode(LocalAPIRequest.self, from: data)
            else { throw LocalAPIError.invalidRequest }
            requestID = request.requestID
            guard request.schemaVersion == LocalAPIContract.version else { throw LocalAPIError.unsupportedVersion }
            guard request.profile == endpoint.profile else { throw LocalAPIError.profileMismatch }
            guard LocalAPIOperation(rawValue: request.operation) != nil else { throw LocalAPIError.unsupportedOperation }
            if let denied = authorization(request) { throw denied }
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
                if let denied = authorization(request) {
                    response = LocalAPIResponse(requestID: request.requestID, error: denied)
                } else {
                    response = await capture(request, instanceID)
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
            if let denied = authorization(request) { throw denied }
            var encoded = try LocalAPIContract.encoder().encode(response)
            if encoded.count > LocalAPIContract.maximumResponseBytes {
                encoded = try LocalAPIContract.encoder().encode(LocalAPIResponse(requestID: requestID, error: .responseTooLarge))
            }
            try io.writeFrame(fd, data: encoded)
        } catch {
            guard !isStopped,
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
