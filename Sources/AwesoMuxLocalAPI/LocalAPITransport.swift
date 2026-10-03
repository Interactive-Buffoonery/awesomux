import Darwin
import Foundation

struct LocalAPIIO {
    let deadline: ContinuousClock.Instant
    let cancelled: @Sendable () -> Bool

    func wait(_ fd: Int32, events: Int16) throws {
        let queue = kqueue()
        guard queue >= 0 else { throw LocalAPIError.transportFailure }
        defer { close(queue) }
        while true {
            if cancelled() { throw LocalAPIError.cancelled }
            let remaining = ContinuousClock.now.duration(to: deadline).components
            guard remaining.seconds >= 0, remaining.seconds > 0 || remaining.attoseconds > 0 else {
                throw LocalAPIError.timeout
            }
            var change = kevent(
                ident: UInt(fd), filter: events == Int16(POLLIN) ? Int16(EVFILT_READ) : Int16(EVFILT_WRITE),
                flags: UInt16(EV_ADD | EV_ENABLE), fflags: 0, data: 0, udata: nil
            )
            var event = kevent()
            var timeout = timespec(tv_sec: Int(remaining.seconds), tv_nsec: Int(remaining.attoseconds / 1_000_000_000))
            let outcome = kevent(queue, &change, 1, &event, 1, &timeout)
            if outcome < 0 {
                if errno == EINTR { continue }
                throw LocalAPIError.transportFailure
            }
            if outcome == 0 { throw LocalAPIError.timeout }
            if cancelled() { throw LocalAPIError.cancelled }
            guard event.flags & UInt16(EV_ERROR) == 0 else { throw LocalAPIError.transportFailure }
            return
        }
    }

    func read(_ fd: Int32, count: Int) throws -> Data {
        var result = Data(count: count)
        var offset = 0
        while offset < count {
            try wait(fd, events: Int16(POLLIN))
            let n = result.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
            }
            if n < 0, errno == EAGAIN || errno == EINTR { continue }
            guard n > 0 else { throw LocalAPIError.cancelled }
            offset += n
        }
        return result
    }

    func readFrame(_ fd: Int32, maximum: Int, oversized: LocalAPIError) throws -> Data {
        let header = try read(fd, count: 4)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0 else { throw LocalAPIError.invalidRequest }
        guard length <= maximum else { throw oversized }
        return try read(fd, count: Int(length))
    }

    func writeFrame(_ fd: Int32, data: Data) throws {
        let frame = Self.frame(data)
        var offset = 0
        while offset < frame.count {
            try wait(fd, events: Int16(POLLOUT))
            let n = frame.withUnsafeBytes { bytes in
                Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), frame.count - offset)
            }
            if n < 0, errno == EAGAIN || errno == EINTR { continue }
            guard n > 0 else { throw LocalAPIError.transportFailure }
            offset += n
        }
    }

    static func frame(_ data: Data) -> Data {
        let length = UInt32(data.count)
        var frame = Data([
            UInt8((length >> 24) & 255),
            UInt8((length >> 16) & 255),
            UInt8((length >> 8) & 255),
            UInt8(length & 255),
        ])
        frame.append(data)
        return frame
    }

    static func writeNonblockingChunk(_ fd: Int32, frame: Data, offset: Int) throws -> Int {
        guard offset < frame.count else { return 0 }
        let count = min(16 * 1024, frame.count - offset)
        let written = frame.withUnsafeBytes { bytes in
            send(fd, bytes.baseAddress!.advanced(by: offset), count, MSG_DONTWAIT)
        }
        if written < 0, errno == EAGAIN || errno == EINTR { return 0 }
        guard written > 0 else { throw LocalAPIError.transportFailure }
        return written
    }

    static func configure(_ fd: Int32) throws {
        guard fd >= 0 else { throw LocalAPIError.transportFailure }
        var enabled: Int32 = 1
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
            fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { throw LocalAPIError.transportFailure }
    }

    static func validatePeer(_ fd: Int32) throws {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { throw LocalAPIError.insecureEndpoint }
    }
}

public enum LocalAPIClient {
    public static func call(_ request: LocalAPIRequest) throws -> LocalAPIResponse {
        let endpoint = try LocalAPIEndpoint(profile: request.profile)
        try endpoint.validateSocket()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalAPIError.transportFailure }
        defer { close(fd) }
        try LocalAPIIO.configure(fd)
        var address = try endpoint.address()
        let outcome = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let io = LocalAPIIO(deadline: .now.advanced(by: .seconds(LocalAPIContract.timeout)), cancelled: { false })
        if outcome != 0 {
            guard errno == EINPROGRESS else { throw LocalAPIError.appUnavailable }
            try io.wait(fd, events: Int16(POLLOUT))
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0
            else { throw LocalAPIError.appUnavailable }
        }
        try endpoint.validateSocket()
        try LocalAPIIO.validatePeer(fd)
        let data = try LocalAPIContract.encoder().encode(request)
        guard data.count <= LocalAPIContract.maximumRequestBytes else { throw LocalAPIError.requestTooLarge }
        try io.writeFrame(fd, data: data)
        let reply = try io.readFrame(fd, maximum: LocalAPIContract.maximumResponseBytes, oversized: .responseTooLarge)
        guard let response = try? LocalAPIContract.decoder().decode(LocalAPIResponse.self, from: reply),
            response.schemaVersion == LocalAPIContract.version,
            response.requestID == request.requestID
        else { throw LocalAPIError.invalidRequest }
        if response.error == nil {
            guard response.profile == request.profile, response.appInstanceID != nil,
                response.capturedAt != nil
            else { throw LocalAPIError.profileMismatch }
        }
        return response
    }
}
