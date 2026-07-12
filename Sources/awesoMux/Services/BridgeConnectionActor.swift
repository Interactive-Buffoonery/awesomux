import AwesoMuxCore
import Darwin
import Dispatch
import Foundation

actor BridgeConnectionActor {
    enum ConnectionError: Error, Equatable {
        case socketCreationFailed
        case socketConfigurationFailed
        case bindFailed
        case insecureSocket
        case listenFailed
        case writeFailed
    }

    struct ConnectionID: Sendable, Hashable {
        fileprivate let rawValue = UUID()
    }

    struct Generation: Sendable, Equatable, Hashable {
        fileprivate let rawValue: UInt64
    }

    /// Test-only generation minter. Production generations are stamped solely by
    /// this actor's promotion counter (`promoteToActive`/`acceptReadyConnections`),
    /// and the `rawValue` stays `fileprivate` so a peer can never forge one. E1's
    /// `BridgePermissionCoordinator` tests, however, must feed distinct
    /// generations — decision routing, session-grant keying, and generation-bump
    /// eviction all hinge on generation identity — without standing up a live
    /// socket. This same-file, `internal` seam is the only way to synthesize one;
    /// `@testable import awesoMux` reaches `internal`, the public surface stays
    /// forge-proof. `#if DEBUG` so a generation minter is never compiled into a
    /// release build (swift test runs debug, so tests keep it).
    #if DEBUG
    static func makeGenerationForTesting(_ rawValue: UInt64) -> Generation {
        Generation(rawValue: rawValue)
    }
    #endif

    struct FrameDelivery: Sendable, Equatable {
        let connection: ConnectionID
        let generation: Generation
        let frame: BridgeFrameReader.Frame
    }

    struct Promotion: Sendable, Equatable {
        let generation: Generation
        let replacedConnection: ConnectionID?
    }

    typealias ConnectionLostHandler = @Sendable (ConnectionID, Generation) async -> Void

    nonisolated let socketPath: String
    nonisolated let frames: AsyncStream<FrameDelivery>

    private let directory: BridgeListenerDirectory
    private let expectedToken: String
    private let expectedSession: String
    private let helloDeadline: TimeInterval
    private let frameContinuation: AsyncStream<FrameDelivery>.Continuation
    private var listenerFD: Int32
    private var listenerSource: DispatchSourceRead?
    private var connections: [ConnectionID: ConnectionState] = [:]
    private var activeConnection: ConnectionID?
    private var connectionLostHandler: ConnectionLostHandler?

    /// Reused across every `readReadyConnection` call. Actor isolation
    /// serializes reads, so one shared 8 KiB scratch buffer is safe and
    /// avoids reallocating it on each read-ready event.
    private var readBuffer = [UInt8](repeating: 0, count: 8 * 1024)
    private var nextGeneration: UInt64 = 0
    private var isShutdown = false

    init(
        expectedToken: String,
        expectedSession: String,
        helloDeadline: TimeInterval = BridgeTunables.helloDeadline,
        socketName: String = "bridge.sock"
    ) throws {
        let directory = try BridgeListenerDirectory.create(socketName: socketName)
        // Bounded (adversarial-review finding, convergent across two lanes):
        // the default `.unbounded` policy decoupled producer speed from the
        // MainActor consumer, so a flooding authenticated helper could grow
        // app memory with valid frames no line-level cap ever sees.
        // `.bufferingOldest` preserves already-queued frames in order; the
        // `deliver` seam treats a `.dropped` yield as the flood signal and
        // closes the connection.
        let stream = AsyncStream.makeStream(
            of: FrameDelivery.self,
            bufferingPolicy: .bufferingOldest(BridgeTunables.frameQueueCap)
        )
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Self.remove(directory)
            throw ConnectionError.socketCreationFailed
        }

        do {
            try Self.configureCloseOnExecAndNonblocking(fd)
            try Self.bind(fd, to: directory.socketPath)
            guard BridgeListenerDirectory.isSecureDirectory(at: directory.directoryPath),
                  chmod(directory.socketPath, 0o600) == 0,
                  Self.isOwnerOnlySocket(at: directory.socketPath)
            else {
                throw ConnectionError.insecureSocket
            }
            guard Darwin.listen(fd, 2) == 0 else { throw ConnectionError.listenFailed }
        } catch {
            Darwin.close(fd)
            Self.remove(directory)
            throw error
        }

        self.directory = directory
        socketPath = directory.socketPath
        self.expectedToken = expectedToken
        self.expectedSession = expectedSession
        self.helloDeadline = helloDeadline
        frames = stream.stream
        frameContinuation = stream.continuation
        listenerFD = fd
    }

    deinit {
        if let listenerSource {
            listenerSource.cancel()
        } else if listenerFD >= 0 {
            Darwin.close(listenerFD)
        }
        for state in connections.values {
            state.readSource.cancel()
            state.helloDeadlineTask?.cancel()
            state.partialDeadlineTask?.cancel()
        }
        Self.remove(directory)
        frameContinuation.finish()
    }

    func start() {
        guard !isShutdown, listenerSource == nil else { return }
        // Dispatch sources report readiness only; their handlers hop back into
        // this actor, which performs every accept/read/close itself. Keeping the
        // fds nonblocking means a stale readiness notification cannot pin the
        // actor while another connection needs its deadline or replacement.
        let source = DispatchSource.makeReadSource(fileDescriptor: listenerFD, queue: .global())
        source.setEventHandler { [weak self] in
            Task { await self?.acceptReadyConnections() }
        }
        let fd = listenerFD
        source.setCancelHandler {
            Darwin.close(fd)
        }
        listenerSource = source
        source.activate()
    }

    func setConnectionLostHandler(_ handler: @escaping ConnectionLostHandler) {
        connectionLostHandler = handler
    }

    func promoteToActive(_ connection: ConnectionID) -> Promotion? {
        guard var state = connections[connection] else { return nil }
        if activeConnection == connection {
            return Promotion(generation: state.generation, replacedConnection: nil)
        }

        guard nextGeneration < UInt64.max else {
            _ = closeConnection(connection)
            return nil
        }
        let replaced = activeConnection
        activeConnection = connection
        nextGeneration += 1
        state.generation = Generation(rawValue: nextGeneration)
        state.helloDeadlineTask?.cancel()
        state.helloDeadlineTask = nil
        connections[connection] = state
        if let replaced, replaced != connection {
            _ = closeConnection(replaced)
        }
        return Promotion(generation: state.generation, replacedConnection: replaced)
    }

    /// Handshake nacks may target the still-valid candidate generation;
    /// acknowledgements are emitted only after promotion made that generation active.
    func send(_ handshake: BridgeHandshake, generation: Generation) async -> Bool {
        let destination: ConnectionID?
        switch handshake {
        case .helloNack:
            destination = connections.first { $0.value.generation == generation }?.key
        case .helloAck:
            destination = activeState(matching: generation)?.0
        case .hello:
            destination = nil
        }
        guard let destination,
              let line = try? handshake.encodedLine()
        else { return false }
        return await write(line, to: destination)
    }

    func send(_ envelope: BridgeEnvelope, generation: Generation) async -> Bool {
        guard case .permissionDecision = envelope.message,
              let destination = activeState(matching: generation),
              let line = try? envelope.encodedLine()
        else {
            return false
        }
        return await write(line, to: destination.0)
    }

    func close(_ connection: ConnectionID) async {
        await closeUnexpectedConnection(connection)
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        if let listenerSource {
            listenerSource.cancel()
        } else if listenerFD >= 0 {
            Darwin.close(listenerFD)
        }
        listenerSource = nil
        listenerFD = -1
        let connectionIDs = Array(connections.keys)
        for connection in connectionIDs { _ = closeConnection(connection) }
        Self.remove(directory)
        frameContinuation.finish()
    }

    private func acceptReadyConnections() {
        guard !isShutdown else { return }
        while true {
            let fd = Darwin.accept(listenerFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return
            }

            let hasHandshakingConnection = connections.keys.contains { $0 != activeConnection }
            if hasHandshakingConnection || (activeConnection == nil && !connections.isEmpty) {
                Darwin.close(fd)
                continue
            }

            do {
                try Self.configureConnection(fd)
            } catch {
                Darwin.close(fd)
                continue
            }

            guard nextGeneration < UInt64.max else {
                Darwin.close(fd)
                continue
            }
            nextGeneration += 1
            let id = ConnectionID()
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
            var state = ConnectionState(fd: fd, generation: Generation(rawValue: nextGeneration), readSource: source)
            connections[id] = state
            source.setEventHandler { [weak self] in
                Task { await self?.readReadyConnection(id) }
            }
            source.setCancelHandler {
                Darwin.close(fd)
            }
            source.activate()
            state.helloDeadlineTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.helloDeadline ?? 0))
                guard !Task.isCancelled else { return }
                await self?.expireHello(for: id)
            }
            connections[id] = state
        }
    }

    private func readReadyConnection(_ id: ConnectionID) async {
        guard let state = connections[id] else { return }
        let capacity = readBuffer.count
        while connections[id] != nil {
            let byteCount = Darwin.read(state.fd, &readBuffer, capacity)
            if byteCount < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                await closeUnexpectedConnection(id)
                return
            }
            guard byteCount > 0 else {
                await closeUnexpectedConnection(id)
                return
            }

            await consume(Data(readBuffer.prefix(byteCount)), for: id)
            if byteCount < capacity { return }
        }
    }

    private func consume(_ data: Data, for id: ConnectionID) async {
        guard var state = connections[id] else { return }
        let result = BridgeFrameReader.consume(
            data,
            pendingTail: state.tail,
            now: Self.monotonicNow(),
            expectedToken: expectedToken,
            expectedSession: expectedSession
        )
        state.tail = result.tail
        schedulePartialDeadline(for: id, state: &state)

        for frame in result.frames {
            switch frame {
            case .handshake(.hello):
                guard !state.hasHello else {
                    await closeUnexpectedConnection(id)
                    return
                }
                state.hasHello = true
                guard deliver(frame, id: id, generation: state.generation) else {
                    await closeUnexpectedConnection(id)
                    return
                }
            case .handshake:
                await closeUnexpectedConnection(id)
                return
            case .envelope(let envelope):
                guard state.hasHello else {
                    await closeUnexpectedConnection(id)
                    return
                }
                guard activeConnection == id, Self.isAllowedInbound(envelope.message) else { continue }
                guard deliver(frame, id: id, generation: state.generation) else {
                    await closeUnexpectedConnection(id)
                    return
                }
            }
        }
        connections[id] = state

        if case .close = result.action { await closeUnexpectedConnection(id) }
    }

    /// Yields one validated frame to the delivery stream, treating a bounded-
    /// buffer drop as the flood signal (adversarial-review finding): a helper
    /// that outruns `BridgeTunables.frameQueueCap` queued frames is broken or
    /// hostile, and the connection is closed — the same posture as the
    /// reader's unterminated-line close. Returns false when the connection
    /// was closed so the caller stops processing this batch.
    private func deliver(
        _ frame: BridgeFrameReader.Frame,
        id: ConnectionID,
        generation: Generation
    ) -> Bool {
        let result = frameContinuation.yield(
            FrameDelivery(connection: id, generation: generation, frame: frame)
        )
        if case .dropped = result {
            return false
        }
        return true
    }

    private func schedulePartialDeadline(for id: ConnectionID, state: inout ConnectionState) {
        state.partialDeadlineTask?.cancel()
        state.partialDeadlineTask = nil
        guard state.tail.startedAt != nil else { return }
        let remaining = BridgeFrameReader.partialLineDeadline
            - Self.monotonicNow().timeIntervalSince(state.tail.startedAt!)
        state.partialDeadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, remaining) + 0.001))
            guard !Task.isCancelled else { return }
            await self?.checkPartialDeadline(for: id)
        }
    }

    private func checkPartialDeadline(for id: ConnectionID) async {
        guard connections[id]?.tail.startedAt != nil else { return }
        await consume(Data(), for: id)
    }

    private func expireHello(for id: ConnectionID) {
        guard connections[id] != nil, activeConnection != id else { return }
        _ = closeConnection(id)
    }

    private func activeState(matching generation: Generation) -> (ConnectionID, ConnectionState)? {
        guard let activeConnection,
              let state = connections[activeConnection],
              state.generation == generation
        else {
            return nil
        }
        return (activeConnection, state)
    }

    private func write(_ line: String, to id: ConnectionID) async -> Bool {
        let deadline = ContinuousClock.now.advanced(
            by: .seconds(BridgeTunables.outboundWriteDeadline)
        )
        while connections[id]?.isWriting == true {
            try? await Task.sleep(for: .milliseconds(1))
            guard !Task.isCancelled, connections[id] != nil else { return false }
            if ContinuousClock.now >= deadline {
                await closeUnexpectedConnection(id)
                return false
            }
        }
        guard var state = connections[id] else { return false }
        state.isWriting = true
        connections[id] = state
        defer {
            if var current = connections[id], current.fd == state.fd {
                current.isWriting = false
                connections[id] = current
            }
        }

        var bytes = Array(line.utf8)
        bytes.append(0x0A)
        var offset = 0
        var retryDelay: Duration = .milliseconds(1)
        while offset < bytes.count {
            guard !Task.isCancelled,
                  let current = connections[id],
                  current.fd == state.fd
            else {
                return false
            }

            let count = bytes.withUnsafeBytes { buffer in
                Darwin.write(state.fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                // Yield actor isolation so deadlines, replacement, and shutdown
                // stay live while a peer applies socket backpressure.
                try? await Task.sleep(for: retryDelay)
                if ContinuousClock.now >= deadline {
                    await closeUnexpectedConnection(id)
                    return false
                }
                retryDelay = min(retryDelay * 2, .milliseconds(50))
                continue
            }
            guard count > 0 else {
                await closeUnexpectedConnection(id)
                return false
            }
            offset += count
            retryDelay = .milliseconds(1)
        }
        return true
    }

    @discardableResult
    private func closeConnection(_ id: ConnectionID) -> (Generation, Bool)? {
        guard let state = connections.removeValue(forKey: id) else { return nil }
        let wasActive = activeConnection == id
        if wasActive { activeConnection = nil }
        state.helloDeadlineTask?.cancel()
        state.partialDeadlineTask?.cancel()
        state.readSource.cancel()
        return (state.generation, wasActive)
    }

    private func closeUnexpectedConnection(_ id: ConnectionID) async {
        guard let (generation, wasActive) = closeConnection(id), wasActive else { return }
        await connectionLostHandler?(id, generation)
    }

    private static func isAllowedInbound(_ message: BridgeMessage) -> Bool {
        switch message {
        case .agentStatus, .paneRename, .handoffNotify, .permissionRequest, .permissionResolved:
            // `permission-resolved` is helper→app (spec §"permission-resolved
            // (helper → app)" and the failure-modes table): the helper's own
            // terminal-state notice the app consumes to tear a prompt down when
            // it can no longer deliver a decision. Admitting it inbound is what
            // makes E1's `BridgePermissionCoordinator.handleHelperResolved` live.
            true
        case .permissionDecision:
            // `permission-decision` is app→helper only; an inbound one is a
            // misdirected/forged frame and is dropped, never surfaced.
            false
        }
    }

    private static func configureCloseOnExecAndNonblocking(_ fd: Int32) throws {
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            throw ConnectionError.socketConfigurationFailed
        }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw ConnectionError.socketConfigurationFailed
        }
    }

    private static func configureConnection(_ fd: Int32) throws {
        try configureCloseOnExecAndNonblocking(fd)
        var noSignal: Int32 = 1
        guard setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        ) == 0 else {
            throw ConnectionError.socketConfigurationFailed
        }
    }

    private static func bind(_ fd: Int32, to path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !pathBytes.isEmpty, pathBytes.count < capacity else {
            throw BridgeListenerDirectory.DirectoryError.socketPathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.copyBytes(from: pathBytes)
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, length)
            }
        }
        guard result == 0 else { throw ConnectionError.bindFailed }
    }

    private static func isOwnerOnlySocket(at path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0
            && status.st_uid == geteuid()
            && status.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK)
            && status.st_mode & 0o077 == 0
    }

    private static func remove(_ directory: BridgeListenerDirectory) {
        _ = Darwin.unlink(directory.socketPath)
        _ = Darwin.rmdir(directory.directoryPath)
    }

    private static func monotonicNow() -> Date {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return Date(timeIntervalSinceReferenceDate: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
    }

    private struct ConnectionState: Sendable {
        let fd: Int32
        var generation: Generation
        let readSource: DispatchSourceRead
        var tail = BridgeFrameReader.PendingTail.empty
        var hasHello = false
        var isWriting = false
        var helloDeadlineTask: Task<Void, Never>?
        var partialDeadlineTask: Task<Void, Never>?

        init(fd: Int32, generation: Generation, readSource: DispatchSourceRead) {
            self.fd = fd
            self.generation = generation
            self.readSource = readSource
        }
    }
}
