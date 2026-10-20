import AwesoMuxBridgeProtocol
import AwesoMuxTestSupport
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif
import Foundation
import Testing
@testable import AwesoMuxBridgeHelperSupport

@Suite(.serialized)
struct HelperConnectionTests {

    @Test
    func emitCommandRunsHandshakeAndPermissionFlowEndToEnd() async throws {
        let server = try TestUnixServer()
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-helper-fixture")
        let fixtureURL = temporaryDirectory.url.appending(path: "events.jsonl")
        defer { withExtendedLifetime(temporaryDirectory) {} }
        let expiresAt = Date().addingTimeInterval(1).timeIntervalSince1970
        try "{\"type\":\"permission-request\",\"id\":\"request\",\"tool\":\"Bash\",\"target\":\"build\",\"expiresAt\":\(expiresAt)}\n"
            .write(to: fixtureURL, atomically: true, encoding: .utf8)

        let serverTask = Task.detached {
            try server.acceptHelloAndAck()
            let request = try server.readEnvelope()
            try server.write(
                BridgeEnvelope(
                    token: "token", session: "session", id: "decision", ts: Date().timeIntervalSince1970,
                    message: .permissionDecision(
                        PermissionDecision(inReplyTo: request.id, decision: .allow, scope: .once, target: "build")
                    )
                ).encodedLine())
        }

        let state = BridgeStateFile(proto: "awesomux-bridge-v1", gen: 1, socket: server.path, token: "token")
        let status = BridgeHelperCommand.run(
            arguments: ["--emit", fixtureURL.path],
            environment: ["AWESOMUX_BRIDGE_STATE": "/state", "AWESOMUX_BRIDGE_SESSION": "session"],
            readState: { _ in state }
        )
        #expect(status == 0)
        try await serverTask.value
    }

    @Test
    func alreadyExpiredPermissionRequestDeniesAndTerminates() async throws {
        // Regression (review P1): an expiresAt at/below now used to exit the
        // wait loop via a nil return that bypassed the expiry sweep — the
        // pending entry never resolved, the outer loop recomputed the same
        // past deadline, and the helper spun at 100% CPU forever instead of
        // fail-closed denying. The fix routes the pre-expired case through
        // the same timeout throw the mid-read expiry takes.
        let server = try TestUnixServer()
        let temporaryDirectory = try TemporaryDirectory(prefix: "awesomux-helper-fixture")
        let fixtureURL = temporaryDirectory.url.appending(path: "events.jsonl")
        defer { withExtendedLifetime(temporaryDirectory) {} }
        let expiresAt = Date().addingTimeInterval(-1).timeIntervalSince1970
        try "{\"type\":\"permission-request\",\"id\":\"stale\",\"tool\":\"Bash\",\"target\":\"build\",\"expiresAt\":\(expiresAt)}\n"
            .write(to: fixtureURL, atomically: true, encoding: .utf8)

        let serverTask = Task.detached { () -> BridgeEnvelope in
            try server.acceptHelloAndAck()
            _ = try server.readEnvelope()  // the permission-request
            return try server.readEnvelope()  // must be the expiry resolution
        }

        let state = BridgeStateFile(proto: "awesomux-bridge-v1", gen: 1, socket: server.path, token: "token")
        let status = BridgeHelperCommand.run(
            arguments: ["--emit", fixtureURL.path],
            environment: ["AWESOMUX_BRIDGE_STATE": "/state", "AWESOMUX_BRIDGE_SESSION": "session"],
            readState: { _ in state }
        )
        // Termination itself is half the regression assertion — the buggy
        // build never returns from run(...).
        #expect(status == 0)
        let resolution = try await serverTask.value
        guard case .permissionResolved(let resolved) = resolution.message else {
            Issue.record("expected permission-resolved, got \(resolution.message)")
            return
        }
        #expect(resolved.inReplyTo == "stale")
        #expect(resolved.reason == .expired)
    }

}

private enum TestSocketError: Error { case system, invalidFrame }

private final class TestUnixServer: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private var connection: Int32 = -1

    init() throws {
        path =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("awesomux-helper-\(UUID().uuidString.prefix(8)).sock").path
        // Glibc's overlay imports SOCK_STREAM as the enum __socket_type, not
        // Int32; musl's imports it as a plain Int32. Normalize per-platform.
        #if canImport(Darwin)
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
        #elseif canImport(Glibc)
            listener = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #elseif canImport(Musl)
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard listener >= 0 else { throw TestSocketError.system }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
        }
        guard bound == 0, listen(listener, 1) == 0 else { throw TestSocketError.system }
    }

    deinit {
        if connection >= 0 { close(connection) }
        close(listener)
        unlink(path)
    }

    func acceptHelloAndAck(session: String = "session", proto: String = "awesomux-bridge-v1") throws {
        var pending = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&pending, 1, 30_000) > 0 else { throw TestSocketError.system }
        connection = accept(listener, nil, nil)
        guard connection >= 0 else { throw TestSocketError.system }
        let line = try readLine()
        guard case .hello = BridgeHandshake.parse(line: line) else { throw TestSocketError.invalidFrame }
        try write(BridgeHandshake.helloAck(session: session, proto: proto, ts: Date().timeIntervalSince1970).encodedLine())
    }

    func readEnvelope() throws -> BridgeEnvelope {
        guard let envelope = BridgeEnvelope.parse(line: try readLine()) else { throw TestSocketError.invalidFrame }
        return envelope
    }

    func write(_ line: String) throws {
        try writeRaw(line + "\n")
    }

    /// Writes bytes verbatim — no frame-terminating newline. Used to stage
    /// buffer-exact patterns that must not form complete lines on the wire.
    func writeRaw(_ text: String) throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        guard setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw TestSocketError.system
        }
        let data = Data(text.utf8)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard clock.now < deadline else { throw TestSocketError.system }
                #if canImport(Darwin)
                    let written = Darwin.write(connection, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                #elseif canImport(Glibc)
                    let written = Glibc.write(connection, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                #elseif canImport(Musl)
                    let written = Musl.write(connection, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                #endif
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw TestSocketError.system }
                offset += written
            }
        }
    }

    private func readLine() throws -> String {
        var bytes: [UInt8] = []
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while true {
            guard clock.now < deadline else { throw TestSocketError.system }
            var pending = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
            guard poll(&pending, 1, 30_000) > 0 else { throw TestSocketError.system }
            var byte: UInt8 = 0
            let count = read(connection, &byte, 1)
            guard count == 1 else { throw TestSocketError.system }
            if byte == 0x0A { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
    }
}
