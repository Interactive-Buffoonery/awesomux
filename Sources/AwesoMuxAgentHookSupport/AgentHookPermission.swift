import AwesoMuxCore
import Darwin
import Foundation

/// One process, one invocation UUID, at most one stdout decision across both
/// transports. Transport failure is deliberately silent provider fall-through.
enum AgentHookPermission {
    static func run(payload: AgentHookPayload, environment: [String: String], output: (String) -> Bool) {
        guard let endpoint = LocalPermissionEndpoint.parse(environment[LocalPermissionEndpoint.environmentKey]),
            let session = payload.providerSessionID,
            let tool = payload.toolName, let summary = payload.permissionSummary,
            !summary.isEmpty, summary.utf8.count <= 1024, tool.utf8.count <= 128,
            let birth = LocalPermissionFiles.processStartMicroseconds(getpid())
        else { return }
        let request = LocalPermissionRequest(
            target: endpoint.target, providerSessionID: session, invocationID: UUID(), toolUseID: payload.toolUseID,
            helperPID: getpid(), helperStartMicroseconds: birth, expiresAt: Date().addingTimeInterval(120),
            tool: LocalPermissionRequest.boundedSummary(tool, bytes: 128),
            summary: LocalPermissionRequest.boundedSummary(summary)
        )
        guard request.isValid(now: Date()) else { return }
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        if bridge(request, endpoint: endpoint, deadline: deadline, output: output) { return }
        let req = endpoint.file("req", id: request.invocationID)
        guard LocalPermissionFiles.write(request, at: req) else { return }
        defer {
            // Removing the exact request signals helper exit to the app. The
            // app owns decision/ACK retention and never replays after restart.
            unlink(req.path)
        }
        while ContinuousClock.now < deadline, Date() < request.expiresAt {
            if let outcome = LocalPermissionFiles.read(LocalPermissionOutcome.self, at: endpoint.file("dec", id: request.invocationID)),
                outcome.identity == request.identity
            {
                if outcome.state == .delivering, let choice = outcome.choice {
                    if outputDecision(choice, output: output) {
                        _ = LocalPermissionFiles.write(request.identity, at: endpoint.file("ack", id: request.invocationID))
                    }
                }
                return
            }
            usleep(100_000)
        }
    }

    private static func outputDecision(_ choice: LocalPermissionChoice, output: (String) -> Bool) -> Bool {
        output("{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"\(choice.rawValue)\"}}}")
    }

    /// A successful response (including a terminal no-decision outcome) ends
    /// this invocation. Once stdout is attempted, fallback is never entered.
    private static func bridge(
        _ request: LocalPermissionRequest, endpoint: LocalPermissionEndpoint,
        deadline: ContinuousClock.Instant, output: (String) -> Bool
    ) -> Bool {
        guard let path = endpoint.socket, var address = LocalPermissionFiles.address(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return false }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN || errno == EWOULDBLOCK else { return false }
            var readiness = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&readiness, 1, 1000) > 0 else { return false }
            var socketError: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0, socketError == 0 else { return false }
        }
        guard fcntl(fd, F_SETFL, 0) == 0, send(request, fd: fd) else { return false }
        var accumulated = Data()
        var bytes = [UInt8](repeating: 0, count: 2048)
        while ContinuousClock.now < deadline, Date() < request.expiresAt {
            let count = recv(fd, &bytes, bytes.count, 0)
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { continue }
            guard count > 0 else { return false }
            accumulated.append(contentsOf: bytes.prefix(count))
            guard accumulated.count <= LocalPermissionFiles.maximumBytes else { return false }
            if let newline = accumulated.firstIndex(of: 10) {
                guard let outcome = try? JSONDecoder().decode(LocalPermissionOutcome.self, from: accumulated[..<newline]),
                    outcome.identity == request.identity
                else { return false }
                if outcome.state == .delivering, let choice = outcome.choice {
                    if outputDecision(choice, output: output) { _ = send(request.identity, fd: fd) }
                }
                return true
            }
        }
        return true
    }

    private static func send<T: Encodable>(_ value: T, fd: Int32) -> Bool {
        guard var data = try? JSONEncoder().encode(value) else { return false }
        data.append(10)
        return data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) } == data.count
    }
}
