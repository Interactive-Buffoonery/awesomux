import AwesoMuxCore
import Darwin
import Foundation

public final class HelperConnection {
    public enum ConnectionError: Error, Equatable {
        case invalidSocketPath
        case connectFailed
        case writeFailed
        case closed
        case timedOut
        case protocolViolation
    }

    private let fd: Int32
    private let token: String
    private let session: String
    private var tail = BridgeFrameReader.PendingTail.empty
    private var queuedFrames: [BridgeFrameReader.Frame] = []
    private var closeAfterQueuedFrames = false
    private let monotonicNow: () -> Date

    public init(
        fileDescriptor: Int32,
        token: String,
        session: String,
        monotonicNow: @escaping () -> Date = HelperConnection.defaultMonotonicNow
    ) {
        fd = fileDescriptor
        self.token = token
        self.session = session
        self.monotonicNow = monotonicNow
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
    }

    deinit {
        Darwin.close(fd)
    }

    public static func connect(
        state: BridgeStateFile,
        session: String,
        monotonicNow: @escaping () -> Date = HelperConnection.defaultMonotonicNow
    ) throws -> HelperConnection {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConnectionError.connectFailed }

        do {
            var noSignal: Int32 = 1
            guard setsockopt(
                fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                socklen_t(MemoryLayout.size(ofValue: noSignal))
            ) == 0 else {
                throw ConnectionError.connectFailed
            }
            try connect(fd: fd, path: state.socket)
            return HelperConnection(fileDescriptor: fd, token: state.token, session: session, monotonicNow: monotonicNow)
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    public func handshake(proto: String, helper: String, wallNow: Date = Date()) throws {
        try write(
            BridgeHandshake.hello(
                proto: proto,
                token: token,
                session: session,
                ts: wallNow.timeIntervalSince1970,
                helper: helper
            ).encodedLine()
        )

        let deadline = monotonicNow().addingTimeInterval(BridgeTunables.helloDeadline)
        while monotonicNow() < deadline {
            let frame = try readFrame(deadline: deadline)
            guard case .handshake(let handshake) = frame else { continue }
            switch handshake {
            case .helloAck(let ackSession, let ackProto, _)
                where ackSession == session && ackProto == proto:
                return
            case .helloAck, .helloNack, .hello:
                throw ConnectionError.protocolViolation
            }
        }
        throw ConnectionError.timedOut
    }

    public func send(_ envelope: BridgeEnvelope) throws {
        try write(envelope.encodedLine())
    }

    /// Returns only app→helper envelope types. The v1 app command surface is
    /// permission decisions; every other envelope is deliberately discarded.
    public func readPermissionDecision(deadline: Date) throws -> BridgeEnvelope? {
        while monotonicNow() < deadline {
            let frame = try readFrame(deadline: deadline)
            if case .envelope(let envelope) = frame,
               case .permissionDecision = envelope.message {
                return envelope
            }
        }
        // An already-passed deadline must surface the SAME way as one that
        // expires mid-read: the caller's timeout arm owns the expiry sweep
        // and the fail-closed deny. Returning nil here exits the wait loop
        // without sweeping — the pending entry never resolves, the outer
        // loop recomputes the same past deadline, and the process spins at
        // 100% CPU forever instead of denying and exiting.
        throw ConnectionError.timedOut
    }

    private func readFrame(deadline: Date) throws -> BridgeFrameReader.Frame {
        while true {
            if !queuedFrames.isEmpty {
                return queuedFrames.removeFirst()
            }
            if closeAfterQueuedFrames {
                throw ConnectionError.protocolViolation
            }

            let remaining = deadline.timeIntervalSince(monotonicNow())
            guard remaining > 0 else { throw ConnectionError.timedOut }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let pollInterval: TimeInterval
            if let tailStartedAt = tail.startedAt {
                // An idle connection can sleep until its real request deadline;
                // only a partial line needs an earlier wake for the reader's
                // resource-hostage deadline.
                let partialRemaining = BridgeFrameReader.partialLineDeadline
                    - monotonicNow().timeIntervalSince(tailStartedAt)
                pollInterval = min(remaining, max(0.001, partialRemaining + 0.001))
            } else {
                pollInterval = remaining
            }
            let timeoutMilliseconds = Int32(min(pollInterval * 1_000, Double(Int32.max)).rounded(.up))
            let pollResult = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw ConnectionError.closed
            }
            if pollResult == 0 {
                let result = BridgeFrameReader.consume(
                    Data(), pendingTail: tail, now: monotonicNow(),
                    expectedToken: token, expectedSession: session
                )
                tail = result.tail
                if case .close = result.action { throw ConnectionError.protocolViolation }
                continue
            }

            var buffer = [UInt8](repeating: 0, count: 8 * 1024)
            let byteCount = Darwin.read(fd, &buffer, buffer.count)
            if byteCount < 0 {
                if errno == EINTR { continue }
                throw ConnectionError.closed
            }
            guard byteCount > 0 else { throw ConnectionError.closed }

            let result = BridgeFrameReader.consume(
                Data(buffer.prefix(byteCount)),
                pendingTail: tail,
                now: monotonicNow(),
                expectedToken: token,
                expectedSession: session
            )
            tail = result.tail
            queuedFrames.append(contentsOf: result.frames)
            if case .close = result.action {
                closeAfterQueuedFrames = true
                if queuedFrames.isEmpty { throw ConnectionError.protocolViolation }
            }
        }
    }

    private func write(_ line: String) throws {
        var data = Data(line.utf8)
        data.append(0x0A)
        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(fd, rawBuffer.baseAddress!.advanced(by: offset), rawBuffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ConnectionError.writeFailed
                }
                guard count > 0 else { throw ConnectionError.writeFailed }
                offset += count
            }
        }
    }

    private static func connect(fd: Int32, path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !pathBytes.isEmpty, pathBytes.count < capacity else {
            throw ConnectionError.invalidSocketPath
        }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.copyBytes(from: pathBytes)
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                while true {
                    let result = Darwin.connect(fd, socketAddress, length)
                    if result == 0 || errno != EINTR { return result }
                }
            }
        }
        guard result == 0 else { throw ConnectionError.connectFailed }
    }

    public static func defaultMonotonicNow() -> Date {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return Date(timeIntervalSinceReferenceDate: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
    }
}
